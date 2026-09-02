import Foundation
import Network
import Testing

@Test func mockServerStreamsEnqueuedLines() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: #"{"id":"a1","time":1,"event":"open","topic":"t"}"#)
    await server.enqueue(line: #"{"id":"a2","time":2,"event":"message","topic":"t","message":"hi"}"#)

    let url = base.appending(path: "t").appending(path: "json")
    let (bytes, response) = try await URLSession.shared.bytes(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    var lines: [String] = []
    for try await line in bytes.lines { lines.append(line) }
    #expect(lines.count == 2)
    #expect(lines[1].contains("\"message\":\"hi\""))
    #expect(await server.receivedRequestPaths.first?.hasPrefix("/t/json") == true)
}

@Test func mockServerCanReturnAnErrorStatus() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.setResponse(status: 401, body: #"{"code":40101,"error":"unauthorized"}"#)

    let url = base.appending(path: "t").appending(path: "json")
    let (_, response) = try await URLSession.shared.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 401)
}

/// `waitForConnection()` must genuinely wait for a NEW connection, not
/// return early against a stale reference to the first, already-closed one.
/// `resolvedEarly` (via the `Signal` actor shared from
/// `KeepaliveWatchdogTests.swift`) pins that: a buggy implementation that
/// treats the closed first connection as still "connected" signals well
/// before the second client actually connects below; the fixed
/// implementation only signals once the second connect happens.
@Test func mockServerWaitsForARealSecondConnection() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: #"{"id":"a1","time":1,"event":"open","topic":"t"}"#)
    let url = base.appending(path: "t").appending(path: "json")

    // Serve and fully drain the first connection so the server closes it.
    let (firstBytes, _) = try await URLSession.shared.bytes(from: url)
    for try await _ in firstBytes.lines {}

    await server.enqueue(line: #"{"id":"a2","time":2,"event":"message","topic":"t","message":"second"}"#)

    let resolvedEarly = Signal()
    Task {
        await server.waitForConnection()
        await resolvedEarly.signal()
    }

    // Give a buggy implementation a generous window to wrongly resolve
    // against the stale, already-closed first connection.
    for _ in 0..<20 {
        if await resolvedEarly.hasFired { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await resolvedEarly.hasFired == false)

    let (secondBytes, _) = try await URLSession.shared.bytes(from: url)
    // Bounded wait (Signal.waitOrTimeout(), ~1s) rather than an unbounded
    // await on the wait task's result: if accept() ever stopped resuming
    // waiters, this must fail the assertion below instead of hanging the
    // whole suite — exactly the failure mode this task exists to avoid.
    #expect(await resolvedEarly.waitOrTimeout() == true)

    var lines: [String] = []
    for try await line in secondBytes.lines { lines.append(line) }
    #expect(lines.count == 1)
    #expect(lines[0].contains("\"message\":\"second\""))
    #expect(await server.receivedRequestPaths.count == 2)
}

/// A `waitForConnection()` call that is still pending when `stop()` runs
/// (no client ever connected) must not leak its continuation — an
/// un-resumed `CheckedContinuation` prints a runtime diagnostic to stderr
/// when it deallocates, which would break this suite's zero-warnings bar
/// the moment a Task 9/10 test calls `waitForConnection()` and then tears
/// its server down without a connection arriving.
@Test func mockServerStopReleasesAPendingWaitForConnection() async throws {
    let server = MockNtfyServer()
    _ = try await server.start()

    let resolved = Signal()
    Task {
        await server.waitForConnection()
        await resolved.signal()
    }

    // Give waitForConnection() a moment to actually register its waiter
    // before stopping the server out from under it.
    try await Task.sleep(for: .milliseconds(50))

    await server.stop()

    #expect(await resolved.waitOrTimeout() == true)
}

/// A request that is not valid UTF-8 (and so cannot be parsed as an HTTP
/// request line at all) must still get a response and a closed connection,
/// rather than being silently dropped and leaving the client to hang.
/// `URLSession` cannot be made to send non-UTF-8 bytes, so this test speaks
/// raw TCP via `NWConnection` directly. A watchdog forces the connection
/// closed after a bounded wait so a regression fails this test cleanly
/// instead of stalling the suite.
@Test func mockServerAnswersBadRequestInsteadOfHangingOnUnparsableBytes() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    guard let port = base.port, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
        Issue.record("server did not report a usable port")
        return
    }

    let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: .tcp)
    conn.start(queue: .global())

    // Force the connection closed after a bounded wait. Created before the
    // very first await below (the `.ready` wait) rather than after it: a raw
    // TCP connection can stick in `.waiting`/`.preparing` with no guaranteed
    // transition to `.ready` or `.failed` on its own — confirmed empirically
    // against a non-routable address, where the connection sat in
    // `.preparing` indefinitely until force-cancelled. Every await in this
    // test must be covered by this one bound, not just the ones after it.
    //
    // `try?` around the sleep would be wrong here: it discards
    // `CancellationError` but does not stop execution, so `conn.cancel()`
    // would run unconditionally, including the moment the `defer` below
    // cancels this task once the test already has its answer. `do`/`catch`
    // only reaches `conn.cancel()` when the sleep actually ran to
    // completion (a genuine 3-second timeout), not when cancelled early.
    let watchdog = Task {
        do {
            try await Task.sleep(for: .seconds(3))
            conn.cancel()
        } catch {
            // Cancelled by the `defer` below because the test already has
            // its answer — nothing to clean up.
        }
    }
    defer { watchdog.cancel() }

    // `ResumeOnce` (from Support/MockNtfyServer.swift, same module) guards
    // against `stateUpdateHandler` firing twice with two different terminal
    // states close together — reassigning it to a no-op from inside itself
    // was confirmed insufficient by a targeted race stress test.
    try await withCheckedThrowingContinuation { (rawCont: CheckedContinuation<Void, Swift.Error>) in
        let cont = ResumeOnce(rawCont)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                cont.resume(returning: ())
            case .failed(let error):
                cont.resume(throwing: error)
            case .cancelled:
                // Only reachable here if the watchdog force-closed the
                // connection before it ever became ready.
                cont.resume(throwing: MockNtfyServerTestError.connectionNeverBecameReady)
            default:
                break
            }
        }
    }

    // Bytes that are not valid UTF-8, so the server cannot even extract a
    // request line out of them. Ignoring the send completion's error is
    // deliberate: a failed send here still leads to the receive below
    // failing or the watchdog firing, so there is no distinct failure mode
    // this test would otherwise miss.
    conn.send(content: Data([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x03]), completion: .contentProcessed { _ in })

    let responseText = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Swift.Error>) in
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
            if let data, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                cont.resume(returning: text)
            } else {
                cont.resume(throwing: error ?? MockNtfyServerTestError.noResponseReceived)
            }
        }
    }

    conn.cancel()
    #expect(responseText.hasPrefix("HTTP/1.1 400"))
}

private enum MockNtfyServerTestError: Swift.Error {
    case noResponseReceived
    case connectionNeverBecameReady
}
