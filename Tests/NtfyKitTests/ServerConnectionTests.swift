import Foundation
import Testing
@testable import NtfyKit

private func makeConnection(
    base: URL,
    topics: [String] = ["alerts"],
    sleeper: Sleeper = ManualSleeper()
) -> ServerConnection {
    ServerConnection(
        endpoint: NtfyEndpoint(baseURL: base, credential: .none),
        topics: topics,
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: NtfyStreamClient(),
        backoff: .standard,
        sleeper: sleeper
    )
}

/// Polls until `condition` holds, or gives up at `timeout`. Preferred here over
/// a fixed `Task.sleep`: every wait in this file is on a real socket handshake,
/// and a fixed wait is either long enough to be slow on every run or short
/// enough to be flaky on a loaded machine. The generous timeout costs nothing
/// on the passing path, which returns as soon as the condition holds.
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        // A cancelled poll means the test task itself is going away; stop
        // polling rather than spinning to the deadline.
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
    }
    return await condition()
}

@Test func reachesOpenStateAndEmitsMessages() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    // Hold the connection open after the two lines are written. With the
    // default close-after-sending, the stream ends the instant the message is
    // delivered and the run loop moves straight on to `.backoff`, racing this
    // test's read of `state` — observed failing on the very first run. Held
    // open, `.open` is a stable state rather than a moment in a transition:
    // the open line is processed before the message line, so by the time the
    // message reaches the collector the state is already `.open`, and nothing
    // can move it while the next read stays pending.
    await server.setCloseAfterSending(false)
    await server.enqueue(line: Fixtures.openEvent)
    await server.enqueue(line: Fixtures.minimalMessage)

    let connection = makeConnection(base: base)
    // The collected events are the task's *return value* rather than a captured
    // local `var`: under Swift 6 strict concurrency, mutating a caller-owned
    // local from inside a `Task` is a data race and does not compile.
    let collector = Task { () -> [NtfyEvent] in
        var received: [NtfyEvent] = []
        for await event in connection.events where event.kind == .message {
            received.append(event)
            break
        }
        return received
    }

    await connection.start()
    let received = await collector.value

    #expect(received.count == 1)
    #expect(received.first?.message == "A1")
    #expect(await connection.state == .open)
    await connection.stop()
}

/// The subscribe URL must name every topic, comma-joined, on one connection.
@Test func subscribesToAllTopicsOnASingleConnection() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.enqueue(line: Fixtures.openEvent)

    let connection = makeConnection(base: base, topics: ["alerts", "deploys", "cron"])
    await connection.start()
    #expect(await waitUntil { await server.receivedRequestPaths.isEmpty == false })

    let paths = await server.receivedRequestPaths
    #expect(paths.first?.hasPrefix("/alerts,deploys,cron/json") == true)
    // "on a single connection" is half the claim: three topics must not mean
    // three sockets. The ManualSleeper parks the post-disconnect backoff, so
    // any second request would be a genuine extra connection, not a retry.
    #expect(paths.count == 1)
    await connection.stop()
}

/// A 401 stops retrying entirely rather than hammering the server (spec §10).
@Test func stopsRetryingAfterUnauthorized() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 401, body: #"{"code":40101,"error":"unauthorized"}"#)

    let connection = makeConnection(base: base)
    await connection.start()

    #expect(await waitUntil { await connection.state == .unauthorized })
    #expect(await server.receivedRequestPaths.count == 1)
    await connection.stop()
}

/// 429 is not terminal the way 401 is: the connection reports itself degraded
/// and waits out the server's retry delay. This is also the only coverage
/// anywhere of `NtfyStreamClient.Error.rateLimited`.
@Test func reportsRateLimitingAsDegradedRatherThanGivingUp() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 429, body: #"{"code":42901,"error":"rate limited"}"#)

    let connection = makeConnection(base: base)
    await connection.start()

    #expect(await waitUntil { await connection.state == .degraded(reason: "rate limited") })
    // The retry is pending on the ManualSleeper rather than abandoned, so
    // exactly one request has been made — no hammering while rate limited.
    #expect(await server.receivedRequestPaths.count == 1)
    await connection.stop()
}

/// After the server drops the connection, the actor enters backoff rather than
/// giving up or spinning.
@Test func entersBackoffWhenTheStreamEnds() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.enqueue(line: Fixtures.openEvent)

    let sleeper = ManualSleeper()
    let connection = makeConnection(base: base, sleeper: sleeper)
    await connection.start()
    // The server closes after writing, so the stream ends on its own.
    _ = await waitUntil { await isInBackoff(connection) }

    if case .backoff = await connection.state {} else {
        Issue.record("expected .backoff, got \(await connection.state)")
    }
    await connection.stop()
}

/// reconnectNow() is what sleep/wake and network-path changes call: it must
/// skip the pending backoff delay instead of waiting it out (spec §5).
@Test func reconnectNowBypassesTheBackoffDelay() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.enqueue(line: Fixtures.openEvent)
    await server.enqueue(line: Fixtures.minimalMessage)

    let sleeper = ManualSleeper()
    let connection = makeConnection(base: base, sleeper: sleeper)
    await connection.start()

    // Waiting for `.backoff` specifically, not just for time to pass: the
    // pending delay this test claims to bypass has to actually exist first.
    // The ManualSleeper never releases it, so a second request can only come
    // from reconnectNow() skipping it — never from the delay elapsing.
    #expect(await waitUntil { await isInBackoff(connection) })
    #expect(await server.receivedRequestPaths.count == 1)

    await server.enqueue(line: Fixtures.openEvent)
    await connection.reconnectNow()

    #expect(await waitUntil { await server.receivedRequestPaths.count >= 2 })

    // The reconnect must resume from the message it already saw, not replay
    // from the beginning. `record()` advanced the "alerts" watermark to the
    // fixture's own `time` (1788353322), and WatermarkResolver backs it off by
    // the 5s margin. Without that, this would read `since=all` and every
    // reconnect would redeliver the whole cache.
    let paths = await server.receivedRequestPaths
    #expect(paths.first?.contains("since=all") == true)
    #expect(paths.count >= 2 && paths[1].contains("since=1788353317"))
    await connection.stop()
}

/// Keepalives, not socket errors, are the liveness signal: after a Mac sleeps a
/// dead TCP connection usually goes silent rather than erroring. So the watchdog
/// has to keep working *after* it has already fired once — a watchdog that fires
/// exactly once per launch would leave the app silently dead on the second
/// stall, with no error anywhere to show for it.
///
/// This is a regression test for a real defect, not a hypothetical: with the
/// watchdog stopped from a detached `defer { Task { ... } }`, the superseded
/// connection's teardown disarmed the watchdog its own replacement had just
/// armed. That variant failed here 20 times out of 20, on the second fire only.
@Test func theWatchdogStaysArmedAfterItHasAlreadyFiredOnce() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    // Hold every connection open and send nothing at all: with no line ever
    // arriving, the watchdog firing is the only thing that can end a
    // connection, so a new request is unambiguous proof that it fired.
    await server.setCloseAfterSending(false)

    let sleeper = ManualSleeper()
    let connection = makeConnection(base: base, sleeper: sleeper)
    await connection.start()
    #expect(await waitUntil { await server.receivedRequestPaths.count >= 1 })

    #expect(await fireWatchdog(server: server, sleeper: sleeper, untilRequests: 2),
            "watchdog did not fire the first time")
    #expect(await fireWatchdog(server: server, sleeper: sleeper, untilRequests: 3),
            "watchdog fired once but was disarmed before it could fire again")

    await connection.stop()
}

/// Releases pending sleeps until the watchdog fires and a reconnect lands.
///
/// It advances repeatedly rather than once because `ManualSleeper` releases the
/// *oldest* pending sleep, and a superseded watchdog arm leaves its sleep
/// pending forever by design (see `ManualSleeper`'s note): releasing one of
/// those is a no-op, so reaching the live arm can take several advances.
private func fireWatchdog(
    server: MockNtfyServer,
    sleeper: ManualSleeper,
    untilRequests count: Int
) async -> Bool {
    for _ in 0..<200 {
        await sleeper.advanceOnePendingSleep()
        if await server.receivedRequestPaths.count >= count { return true }
        do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
    }
    return await server.receivedRequestPaths.count >= count
}

private func isInBackoff(_ connection: ServerConnection) async -> Bool {
    if case .backoff = await connection.state { return true }
    return false
}
