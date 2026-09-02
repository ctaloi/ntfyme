import Foundation
import Network

/// A minimal loopback HTTP server that speaks just enough to imitate ntfy's
/// ndjson streaming endpoint. Binds port 0 so parallel tests never collide.
actor MockNtfyServer {
    enum Error: Swift.Error {
        /// `start()` reached `.ready` but the OS never reported an assigned
        /// port. Surfaced loudly instead of silently substituting port 0,
        /// which would otherwise fail later as a confusing connection error
        /// far from its real cause.
        case listenerHasNoPort
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

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
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
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                // Not a readable HTTP request (no bytes, or not valid UTF-8).
                // Answer instead of silently dropping the connection, which
                // would otherwise leave the client hanging until its own
                // timeout rather than seeing a failure.
                Task { await self.respondBadRequest(on: conn) }
                return
            }
            Task { await self.respond(to: request, on: conn) }
        }
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

        if let errorBody {
            let head = """
            HTTP/1.1 \(status) Error\r
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
