import Foundation
import Network

/// Wraps a `CheckedContinuation` so a persistent, possibly-not-serialized
/// callback — like `NWListener`/`NWConnection`'s `stateUpdateHandler`, which
/// can be invoked again with a second terminal state — can never resume the
/// continuation twice. Reassigning the handler to a no-op from inside itself
/// is *not* sufficient on its own: a targeted stress test that forced two
/// terminal states to race (500 iterations, watchdog armed for 0ms so it
/// raced against the listener's own `.ready`/`.failed` transition) hit the
/// Swift Concurrency runtime's fatal "resumed more than once" crash without
/// this guard, and zero crashes across the same 500 iterations with it.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Swift.Error>

    init(_ continuation: CheckedContinuation<T, Swift.Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let alreadyResumed = resumed
        resumed = true
        lock.unlock()
        if !alreadyResumed { continuation.resume(returning: value) }
    }

    func resume(throwing error: Swift.Error) {
        lock.lock()
        let alreadyResumed = resumed
        resumed = true
        lock.unlock()
        if !alreadyResumed { continuation.resume(throwing: error) }
    }
}

/// A minimal loopback HTTP server that speaks just enough to imitate ntfy's
/// ndjson streaming endpoint. Binds port 0 so parallel tests never collide.
actor MockNtfyServer {
    enum Error: Swift.Error {
        /// `start()` reached `.ready` but the OS never reported an assigned
        /// port. Surfaced loudly instead of silently substituting port 0,
        /// which would otherwise fail later as a confusing connection error
        /// far from its real cause.
        case listenerHasNoPort
        /// The listener never reached `.ready` or `.failed` within the
        /// bound below (e.g. stuck in `.waiting`/`.preparing` — a macOS
        /// Local Network permission prompt can do this, as can other
        /// OS-level stalls) and was force-cancelled instead.
        case startTimedOut
    }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var pendingLines: [String] = []
    private var status = 200
    private var errorBody: String?
    /// Close the socket once the queued lines are written. Required for a
    /// client using `bytes.lines` to observe end-of-stream at all.
    private var closeAfterSending = true
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedRequestPaths: [String] = []

    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            Task { await self?.accept(conn) }
        }

        // Force the listener closed after a bounded wait. Armed before the
        // continuation below can even suspend: a raw `NWListener`/`NWConnection`
        // can stick in `.waiting`/`.preparing` with no guaranteed transition to
        // a terminal state on its own (confirmed empirically for the analogous
        // client-side wait in MockNtfyServerTests.swift, against a connection
        // that stalled indefinitely until force-cancelled) — a macOS Local
        // Network permission prompt is one realistic way this listener could
        // stall. `start()` is the first line of every test in this file, so an
        // unbounded wait here would hang the entire suite, not just one test.
        //
        // `try?` around the sleep would be wrong here: it discards
        // `CancellationError` but does not stop execution, so
        // `listener.cancel()` would run unconditionally — including the
        // instant `defer` cancels this task below on the normal, successful
        // path, tearing down every listener moments after it started. `do`/
        // `catch` only reaches `listener.cancel()` when the sleep actually
        // ran to completion (a genuine 3-second timeout), not when it was
        // cancelled early.
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(3))
                listener.cancel()
            } catch {
                // Cancelled by the `defer` below because start() already
                // finished (success or failure) — nothing to clean up.
            }
        }
        defer { watchdog.cancel() }

        let port: UInt16 = try await withCheckedThrowingContinuation { rawCont in
            let cont = ResumeOnce(rawCont)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        cont.resume(returning: port)
                    } else {
                        cont.resume(throwing: Error.listenerHasNoPort)
                    }
                case .failed(let error):
                    cont.resume(throwing: error)
                case .cancelled:
                    // Only reachable if the watchdog force-cancelled the
                    // listener before it ever became ready.
                    cont.resume(throwing: Error.startTimedOut)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }

        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        // Release any waitForConnection() call still pending (no client ever
        // connected). Left un-resumed, that continuation would only be
        // dropped when this actor deallocates, printing a runtime "leaked
        // its continuation" diagnostic and leaving the caller suspended
        // forever in the meantime.
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Queue a line to be written to the *next* connection served. Must be
    /// called before the client that should receive it connects: `respond`
    /// drains `pendingLines` as soon as a request is served, and that drain
    /// races an `enqueue` call made after `waitForConnection()` returns,
    /// since the two are dispatched to the actor from different execution
    /// contexts with no ordering guarantee between them.
    func enqueue(line: String) { pendingLines.append(line) }

    /// Pass `false` to hold the connection open after writing, so a test can
    /// drop it mid-stream with `closeCurrentConnection()`.
    func setCloseAfterSending(_ value: Bool) { closeAfterSending = value }

    /// Suspends until a client has connected. `connection` is cleared back
    /// to `nil` synchronously, as part of serving a request that closes the
    /// connection, so this correctly waits for a genuine new connection on
    /// every call — not just the first — rather than returning immediately
    /// against a stale, already-closed one.
    func waitForConnection() async {
        guard connection == nil else { return }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    /// Every raw request served, in order. See `respond(to:on:)`.
    private(set) var receivedRequests: [String] = []

    /// The body of the last request served: everything after the blank line
    /// that ends the headers. Empty when there was none (a GET) or when the
    /// request arrived split across reads — `accept` performs a single
    /// `receive`, which is enough for the small publish bodies these tests
    /// send but is not a general-purpose HTTP read.
    var lastRequestBody: String {
        guard let request = receivedRequests.last,
              let separator = request.range(of: "\r\n\r\n") else { return "" }
        return String(request[separator.upperBound...])
    }

    func setResponse(status: Int, body: String) {
        self.status = status
        self.errorBody = body
    }

    func closeCurrentConnection() {
        connection?.cancel()
        connection = nil
    }

    private func accept(_ conn: NWConnection) {
        connection = conn
        let toWake = connectionWaiters
        connectionWaiters.removeAll()
        toWake.forEach { $0.resume() }
        conn.start(queue: .global())
        readRequest(from: conn, accumulated: Data())
    }

    /// Reads until the whole request has arrived, rather than assuming one
    /// `receive` returns it.
    ///
    /// It does for a GET, which is all this server served until publishing
    /// existed. `URLSession` writes a POST's headers and body as separate
    /// TCP segments, so a single read returns the headers alone — which
    /// showed up as every assertion about a published *body* seeing an empty
    /// string, while the same tests' assertions about method and headers
    /// passed.
    private func readRequest(from conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = Self.completeRequest(from: buffer) {
                Task { await self.respond(to: request, on: conn) }
            } else if Self.cannotBecomeARequest(buffer) || isComplete || data == nil {
                // The client closed, or sent nothing readable, before a
                // complete request arrived. Answer rather than silently
                // dropping the connection, which would leave it hanging
                // until its own timeout instead of seeing a failure.
                Task { await self.respondBadRequest(on: conn) }
            } else {
                Task { await self.readRequest(from: conn, accumulated: buffer) }
            }
        }
    }

    /// The request as text once all of it has arrived, or `nil` while it is
    /// still incomplete.
    ///
    /// Completeness is judged on the bytes, and only the header block is
    /// decoded to find `Content-Length` — decoding the whole partial buffer
    /// on every read would fail spuriously whenever a read boundary landed
    /// inside a multi-byte character, which the non-ASCII title test sends
    /// on purpose.
    ///
    /// `nonisolated` and `static`: called from the `receive` completion,
    /// which runs off the actor.
    private nonisolated static func completeRequest(from buffer: Data) -> String? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: buffer[buffer.startIndex..<separator.lowerBound],
                                   encoding: .utf8)
        else { return nil }

        let bodyBytes = buffer.distance(from: separator.upperBound, to: buffer.endIndex)
        guard bodyBytes >= (contentLength(in: headers) ?? 0) else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Whether waiting for more bytes is pointless: the header block has
    /// not ended and what has arrived is not even text, so no continuation
    /// of it can be an HTTP request.
    ///
    /// Without this, "keep reading until the request is complete" turns the
    /// unparsable-bytes case into a hang — a client that sends garbage and
    /// holds the connection open waits forever, which is the exact
    /// behaviour `mockServerAnswersBadRequestInsteadOfHangingOnUnparsableBytes`
    /// exists to prevent (and which caught this).
    ///
    /// Only checked before the terminator, never after: headers are ASCII,
    /// but a read boundary inside a body can land mid-character, and
    /// treating *that* as unparsable would fail the non-ASCII title test.
    private nonisolated static func cannotBecomeARequest(_ buffer: Data) -> Bool {
        buffer.range(of: Data("\r\n\r\n".utf8)) == nil
            && String(data: buffer, encoding: .utf8) == nil
    }

    private nonisolated static func contentLength(in headers: String) -> Int? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Clears `connection` back to `nil` if it still refers to `conn`. Used
    /// wherever a request handler decides to close its connection, so
    /// `waitForConnection()` correctly waits for the next genuine connect
    /// instead of returning immediately against a stale, closed one. Guarded
    /// by identity so a request handler for an old, already-superseded
    /// connection can never clear a newer connection that has since replaced
    /// it in `accept(_:)`.
    private func clearConnectionIfCurrent(_ conn: NWConnection) {
        if connection === conn { connection = nil }
    }

    private func respondBadRequest(on conn: NWConnection) {
        clearConnectionIfCurrent(conn)
        let head = """
        HTTP/1.1 400 Bad Request\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func respond(to request: String, on conn: NWConnection) {
        if let requestLine = request.split(separator: "\r\n").first {
            let parts = requestLine.split(separator: " ")
            if parts.count >= 2 { receivedRequestPaths.append(String(parts[1])) }
        }
        // The whole raw request, for tests that need more than the path:
        // publishing is asserted on its method, its `Authorization` and
        // `Content-Type` headers, and its JSON body, none of which the path
        // shows. Kept as the raw text rather than parsed into a request
        // type — a parser here would be a second, untested HTTP
        // implementation, and every assertion against it would really be an
        // assertion about the parser.
        receivedRequests.append(request)

        if let errorBody {
            let head = """
            HTTP/1.1 \(status) \((200...299).contains(status) ? "OK" : "Error")\r
            Content-Type: application/json\r
            Content-Length: \(errorBody.utf8.count)\r
            Connection: close\r
            \r

            """
            // The error response always closes, so clear eagerly here (on
            // the actor, before the async send even starts) rather than from
            // the send completion, which runs off the actor and would leave
            // a window where `connection` still looks live to a concurrent
            // `waitForConnection()` call.
            clearConnectionIfCurrent(conn)
            conn.send(content: Data((head + errorBody).utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        // No Content-Length: the body is delimited by connection close, which
        // is what makes open-ended streaming possible over HTTP/1.1.
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/x-ndjson\r
        Connection: close\r
        \r

        """
        let body = pendingLines.map { $0 + "\n" }.joined()
        pendingLines.removeAll()
        let shouldClose = closeAfterSending
        // Same reasoning as the error-response path above: clear eagerly,
        // synchronously, before scheduling the send, not from its completion.
        if shouldClose { clearConnectionIfCurrent(conn) }
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            if shouldClose { conn.cancel() }
        })
    }
}
