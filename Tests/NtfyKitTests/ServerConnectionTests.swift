import Foundation
import Testing
@testable import NtfyKit

/// `topics` here is shorthand for "one un-synced watermark per topic", which is
/// what `ServerConnection` now takes: the subscribed set is derived from the
/// watermarks rather than passed alongside them.
private func makeConnection(
    base: URL,
    topics: [String] = ["alerts"],
    watermarks: [TopicWatermark]? = nil,
    sleeper: Sleeper = ManualSleeper(),
    cacheWindow: TimeInterval = 12 * 3600
) -> ServerConnection {
    ServerConnection(
        endpoint: NtfyEndpoint(baseURL: base, credential: .none),
        watermarks: watermarks ?? topics.map { TopicWatermark(topic: $0, lastMessageTime: nil) },
        client: NtfyStreamClient(),
        backoff: .standard,
        sleeper: sleeper,
        cacheWindow: cacheWindow
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
    // Events are collected into an actor rather than a local `var` (mutating a
    // caller-owned local from a `Task` is a data race under Swift 6 and does
    // not compile) — and, more importantly, awaited via `waitUntil` rather than
    // `await collector.value`. The connection is deliberately held open, so
    // there is no end-of-stream to end that `for await`: if the message never
    // arrived, awaiting the task's value would hang the entire suite instead of
    // failing this one test. Every wait in this file is bounded.
    let collected = EventCollector()
    let collector = Task {
        for await event in connection.events where event.kind == .message {
            await collected.append(event)
            break
        }
    }
    defer { collector.cancel() }

    await connection.start()
    #expect(await waitUntil { await collected.events.isEmpty == false })

    let received = await collected.events
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

/// `.unauthorized` is terminal until the credential changes — but "until the
/// credential changes" has to mean something. The unauthorized branch ends its
/// run loop by returning, and leaving that finished task in `runTask` made
/// `start()`'s `runTask == nil` guard reject every later call, so a server
/// whose token the user had just fixed could never be restarted and `start()`
/// silently did nothing.
@Test func startWorksAgainAfterUnauthorized() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 401, body: #"{"code":40101,"error":"unauthorized"}"#)

    let connection = makeConnection(base: base)
    await connection.start()
    #expect(await waitUntil { await connection.state == .unauthorized })
    #expect(await server.receivedRequestPaths.count == 1)

    // A second connect attempt is the observable proof, not a state read: a
    // silently ignored `start()` leaves the state at `.unauthorized` too.
    await connection.start()
    #expect(await waitUntil { await server.receivedRequestPaths.count >= 2 },
            "start() after .unauthorized was silently ignored")
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

    #expect(await waitUntil { await connection.state == .degraded(reason: .rateLimited) })
    // The retry is pending on the ManualSleeper rather than abandoned, so
    // exactly one request has been made — no hammering while rate limited.
    #expect(await server.receivedRequestPaths.count == 1)
    await connection.stop()
}

/// Spec §10: HTTP 400 `40008` means this client built a `since` the server
/// rejected. It is a client bug — log loudly, fall back to `since=all`, and do
/// not retry the rejected value.
///
/// Without a dedicated catch the typed `invalidSince` error falls into the
/// generic branch, and the result is not merely a wrong value but an unbounded
/// loop: degrade → backoff → reconnect → the resolver rebuilds the identical
/// `since` → 400 again, forever.
@Test func fallsBackToSinceAllAfterTheServerRejectsTheSinceParameter() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 400, body: #"{"code":40008,"error":"invalid since parameter"}"#)

    // A real watermark is load-bearing: with the default `nil` one the resolver
    // already returns `.all`, so the first request would be indistinguishable
    // from the fallback and this test would prove nothing.
    let sleeper = ManualSleeper()
    let connection = makeConnection(
        base: base,
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: Date(timeIntervalSince1970: 1788353322))],
        sleeper: sleeper
    )
    await connection.start()

    // Wait for `.backoff`, not merely for the request to be recorded. The mock
    // appends the path at request receipt, so at that moment the 400 may not
    // have been processed yet and the watchdog armed for this attempt is still
    // live — advancing the sleeper then fires it, reconnecting before
    // `forceSinceAll` has been set. Observed flaking 1 run in 3 that way.
    // `.backoff` is reached only after the catch has run and `connectOnce`'s
    // own teardown has disarmed the watchdog, so from here the only pending
    // sleep that can do anything is the backoff delay.
    #expect(await waitUntil { await isInBackoff(connection) })
    let first = await server.receivedRequestPaths[0]
    #expect(first.contains("since=1788353317"))

    // Advance exactly twice rather than using `advanceUntilRequestCount`. That
    // helper advances on a timer until the count is reached, and the second
    // attempt's request is recorded some time *after* its watchdog is armed —
    // so a further blind advance lands on that live arm, fires it, and replaces
    // the in-flight `since=all` attempt with a fresh loop that has already
    // consumed the fallback. Observed as a rare flake exactly that way.
    //
    // Two sleeps are pending here and their order is fixed: the first attempt's
    // watchdog arm, disarmed by `connectOnce`'s teardown and therefore inert,
    // then the backoff delay.
    await sleeper.waitForPendingSleeps(atLeast: 2)
    await sleeper.advanceOnePendingSleep()
    await sleeper.advanceOnePendingSleep()

    // The mock keeps answering 400, so if the fallback did not exist the second
    // request would repeat `since=1788353317` rather than fail to happen — the
    // assertion below distinguishes the two.
    #expect(await waitUntil { await server.receivedRequestPaths.count >= 2 },
            "no second attempt was made")
    let second = await server.receivedRequestPaths[1]
    #expect(second.contains("since=all"))
    #expect(second.contains("since=1788353317") == false)

    await connection.stop()
}

/// Spec §10: a watermark older than the server's cache window is detectable
/// before the request goes out, and a silent full-cache replay must never be
/// mistaken for a clean resume.
///
/// Nothing is enqueued and the connection is held open, so no line ever arrives
/// to overwrite the state with `.open`. That makes the observation stable — the
/// production signal itself is a flicker in a level-triggered enum, which is
/// why the durable half of "surfaced" is the log line and why carrying the gap
/// somewhere a consumer can latch it is deferred to the persistence plan.
@Test func detectsAHistoryGapWhenResumingFromAnOutOfWindowWatermark() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setCloseAfterSending(false)

    let connection = makeConnection(
        base: base,
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: Date(timeIntervalSinceNow: -48 * 3600))],
        cacheWindow: 12 * 3600
    )
    await connection.start()

    #expect(await waitUntil { await connection.state == .degraded(reason: .historyGap) })
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

/// `stop()` must be final even when the run loop is mid-stream.
///
/// `await watchdog.pet()` is a cross-actor hop, so `stop()` can run to
/// completion while the loop sits on it, and `pet()` is non-async-throwing —
/// nothing stops the loop resuming afterwards and writing `state = .open` over
/// `.idle`. Nothing is left running to correct that, so the connection would
/// report itself connected forever.
///
/// The burst is what puts the loop mid-stream when `stop()` lands: every line
/// is another hop, and every `open` line another chance to write state.
///
/// Both numbers below were calibrated against the unguarded code rather than
/// guessed, because each governs a different half of the race:
///
/// - The **burst** has to still be in flight when `stop()` lands. `waitUntil`
///   polls on a 10ms tick, so a short burst is long since drained by then and
///   the loop is parked in `next()`, where cancellation is handled correctly
///   and the bug cannot show. Measured per cycle: 400 lines caught it 5 times
///   in 10, 1500 caught it 10 times in 10.
/// - The **repeat** is needed because one `stop()` offers exactly one chance.
///   The loop's resumption from `pet()` and `stop()`'s tail both end up queued
///   on this actor and which runs first is scheduler-dependent, so a single
///   cycle is a coin flip (measured 8 catches in 20). Only one resumption is
///   possible after cancellation, so power comes from repeating.
@Test func stopIsFinalEvenWithEventsInFlight() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setCloseAfterSending(false)

    for _ in 0..<12 {
        await server.enqueue(line: Fixtures.openEvent)
        for _ in 0..<1500 {
            await server.enqueue(line: Fixtures.minimalMessage)
            await server.enqueue(line: Fixtures.openEvent)
        }

        let collected = EventCollector()
        let connection = makeConnection(base: base)
        let collector = Task {
            for await event in connection.events { await collected.append(event) }
        }
        defer { collector.cancel() }

        await connection.start()
        // Stop while the burst is still being consumed, not before it starts.
        #expect(await waitUntil { await collected.events.isEmpty == false })
        await connection.stop()

        #expect(await connection.state == .idle)
        // And it must *stay* idle: the offending write lands on the loop's next
        // resumption, which is after stop() has already returned.
        try await Task.sleep(for: .milliseconds(20))
        #expect(await connection.state == .idle)
    }

    // The matching "no events yielded after stop()" half is deliberately not
    // asserted by counting. `events` is a buffered AsyncStream drained by a
    // separate task, so a count still rising after stop() is legitimate drain
    // of pre-stop yields, indistinguishable from a post-stop yield without a
    // seam into the actor. The single guard above governs both the state write
    // and the yield, so the state assertion pins both.
}

/// A stopped connection must stay stopped. Sleep/wake and network-path changes
/// fan `reconnectNow()` out across every server without filtering, so a server
/// the user deliberately turned off would otherwise silently come back the
/// moment the lid opens — invisible today, user-visible the day the UI lands.
@Test func reconnectNowDoesNotRestartAStoppedConnection() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setCloseAfterSending(false)
    await server.enqueue(line: Fixtures.openEvent)

    let connection = makeConnection(base: base)
    await connection.start()

    // Wait for `.open`, NOT for `receivedRequestPaths` — this test asserts
    // `.idle` after `stop()`, so its precondition has to establish where the
    // run loop *is*, not merely that a request arrived. The mock appends the
    // path at request receipt, before it sends the body, so a path can be
    // recorded while the `open` line is still in flight and the loop is parked
    // at `await watchdog.pet()`, from which it resumes after `stop()` and
    // writes `state = .open` over the `.idle` asserted below.
    //
    // `.open` is the stronger precondition and is deterministic: the loop
    // writes it only after `pet()` has returned for that line, and with exactly
    // one line enqueued the next `next()` blocks forever on the held-open
    // connection. So once `.open` is observed the loop is parked in `next()`,
    // where cancellation is handled correctly, and it can never be at `pet()`
    // again. That holds independently of the production guard, which is the
    // point: this test should not depend on the defect it is not testing.
    #expect(await waitUntil { await connection.state == .open })
    #expect(await server.receivedRequestPaths.count == 1)

    await connection.stop()
    #expect(await connection.state == .idle)

    await connection.reconnectNow()

    // A negative assertion, so it has to be given a real chance to fail rather
    // than asserted immediately: wait out a window many times longer than the
    // ~10ms a loopback connect takes here, and require no second request in it.
    let reconnected = await waitUntil(timeout: .milliseconds(500)) {
        await server.receivedRequestPaths.count >= 2
    }
    #expect(reconnected == false)
    #expect(await connection.state == .idle)
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

    #expect(await advanceUntilRequestCount(server: server, sleeper: sleeper, count: 2),
            "watchdog did not fire the first time")
    #expect(await advanceUntilRequestCount(server: server, sleeper: sleeper, count: 3),
            "watchdog fired once but was disarmed before it could fire again")

    await connection.stop()
}

/// Releases pending sleeps until `count` requests have reached the server —
/// whether the sleep standing in the way is a watchdog arm or a backoff delay.
///
/// It advances repeatedly rather than once because `ManualSleeper` releases the
/// *oldest* pending sleep, and a superseded watchdog arm leaves its sleep
/// pending forever by design (see `ManualSleeper`'s note): releasing one of
/// those is a no-op, so reaching the live sleep can take several advances.
private func advanceUntilRequestCount(
    server: MockNtfyServer,
    sleeper: ManualSleeper,
    count: Int
) async -> Bool {
    for _ in 0..<200 {
        await sleeper.advanceOnePendingSleep()
        if await server.receivedRequestPaths.count >= count { return true }
        do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
    }
    return await server.receivedRequestPaths.count >= count
}

/// Somewhere for a collecting `Task` to put events that is not a caller-owned
/// local `var`, which Swift 6 strict concurrency rejects as a data race.
private actor EventCollector {
    private(set) var events: [NtfyEvent] = []
    func append(_ event: NtfyEvent) { events.append(event) }
}

private func isInBackoff(_ connection: ServerConnection) async -> Bool {
    if case .backoff = await connection.state { return true }
    return false
}
