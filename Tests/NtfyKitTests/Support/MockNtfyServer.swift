import Foundation
import Network

/// A minimal loopback HTTP server that speaks just enough to imitate ntfy's
/// ndjson streaming endpoint. Binds port 0 so parallel tests never collide.
actor MockNtfyServer {
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
                    cont.resume(returning: listener.port?.rawValue ?? 0)
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

    func enqueue(line: String) { pendingLines.append(line) }

    /// Pass `false` to hold the connection open after writing, so a test can
    /// drop it mid-stream with `closeCurrentConnection()`.
    func setCloseAfterSending(_ value: Bool) { closeAfterSending = value }

    /// Suspends until a client has connected.
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
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
            Task { await self.respond(to: request, on: conn) }
        }
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
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            if shouldClose { conn.cancel() }
        })
    }
}
