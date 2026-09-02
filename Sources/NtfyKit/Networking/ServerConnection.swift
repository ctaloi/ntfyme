import Foundation

/// Owns one long-lived connection to one server, covering every subscribed
/// topic on that server (spec §5).
public actor ServerConnection {
    public private(set) var state: ConnectionState = .idle

    private let endpoint: NtfyEndpoint
    private let topics: [String]
    private var watermarks: [TopicWatermark]
    private let client: NtfyStreamClient
    private let backoff: BackoffPolicy
    private let sleeper: Sleeper
    private let watchdog: KeepaliveWatchdog
    private let cacheWindow: TimeInterval

    private var runTask: Task<Void, Never>?
    private var attempt = 0

    /// Created eagerly in `init`, not lazily on first access. A lazy stream
    /// leaves `continuation` nil until something reads `events`, so any message
    /// arriving before the first read is silently dropped — and whether that
    /// happens depends on task scheduling. `AsyncStream` buffers by default, so
    /// an eager stream loses nothing.
    private let continuation: AsyncStream<NtfyEvent>.Continuation
    public nonisolated let events: AsyncStream<NtfyEvent>

    public init(
        endpoint: NtfyEndpoint,
        topics: [String],
        watermarks: [TopicWatermark],
        client: NtfyStreamClient = NtfyStreamClient(),
        backoff: BackoffPolicy = .standard,
        sleeper: Sleeper = SystemSleeper(),
        watchdogTimeout: Duration = .seconds(90),
        cacheWindow: TimeInterval = 12 * 3600
    ) {
        var capturedContinuation: AsyncStream<NtfyEvent>.Continuation!
        self.events = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation

        self.endpoint = endpoint
        self.topics = topics
        self.watermarks = watermarks
        self.client = client
        self.backoff = backoff
        self.sleeper = sleeper
        self.watchdog = KeepaliveWatchdog(timeout: watchdogTimeout, sleeper: sleeper)
        self.cacheWindow = cacheWindow
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.runLoop() }
    }

    public func stop() async {
        // The one suspension point goes FIRST, so everything after it runs
        // without releasing this actor. Cancelling before the await instead
        // leaves a window in which anything serviced during it — a watchdog
        // fire, or a concurrent `start()` — installs a fresh run loop that the
        // resuming `stop()` never clears, leaving `state == .idle` while a live
        // loop reconnects forever. With the suspension-free tail below, any
        // such loop is cancelled and cleared on the way out.
        await watchdog.stop()
        runTask?.cancel()
        runTask = nil
        state = .idle
    }

    /// Called on wake from sleep and when the network path becomes satisfied.
    /// Cancels any pending backoff so the reconnect is immediate.
    public func reconnectNow() {
        // Wake and network-path changes fan out to every server's
        // `reconnectNow()` without filtering, so this has to decline for
        // itself: a server the user deliberately stopped must not come back
        // when the lid opens. `start()` is how a stopped connection resumes.
        guard runTask != nil else { return }
        guard state != .unauthorized else { return }
        attempt = 0
        runTask?.cancel()
        runTask = Task { await self.runLoop() }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await connectOnce()
                // A clean end of stream is still a disconnect; back off and retry.
                guard !Task.isCancelled else { return }
                await waitBeforeRetry()
            } catch NtfyStreamClient.Error.unauthorized {
                // Guarded like every other branch: a 401 already in flight when
                // stop() ran must not write state over `.idle` on its way out.
                guard !Task.isCancelled else { return }
                state = .unauthorized
                await watchdog.stop()
                return
            } catch NtfyStreamClient.Error.rateLimited(let retryAfter) {
                guard !Task.isCancelled else { return }
                state = .degraded(reason: "rate limited")
                // An explicit `catch { return }` rather than `try?`: a cancelled
                // sleep means stop()/reconnectNow() superseded this loop, and
                // `try?` would swallow that and fall through to another connect
                // attempt before the loop condition could act on it.
                do {
                    try await sleeper.sleep(for: .seconds(Int(retryAfter ?? 60)))
                } catch {
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = .degraded(reason: String(describing: error))
                await waitBeforeRetry()
            }
        }
    }

    private func connectOnce() async throws {
        state = .connecting

        let resolution = WatermarkResolver.resolve(watermarks: watermarks, cacheWindow: cacheWindow)
        if resolution.hasHistoryGap {
            // Surfaced rather than swallowed: the server will replay its whole
            // cache and some messages are simply unrecoverable (spec §10).
            state = .degraded(reason: "history gap: watermark predates server cache")
        }

        let request = try endpoint.streamRequest(topics: topics, since: resolution.since)

        await watchdog.start { [weak self] in
            await self?.handleWatchdogTimeout()
        }

        // The watchdog is stopped inline, on this task, rather than from a
        // `defer { Task { ... } }`. A detached teardown task escapes this run
        // loop's cancellation scope — `Task.isCancelled` is false inside a
        // freshly spawned task — so a superseded connection would stop the
        // watchdog its *replacement* had just armed. `pet()` then returns
        // silently on a nil handler and the watchdog never fires again: the
        // liveness signal would work exactly once per process.
        //
        // Both exits are guarded, so a superseded loop deliberately leaves the
        // watchdog alone; the loop that replaced it owns it.
        do {
            for try await element in client.stream(request) {
                await watchdog.pet()
                // `pet()` is a cross-actor hop, so `stop()` can run to
                // completion while this loop is suspended on it — and `pet()`
                // is non-async-throwing, so nothing stops this loop resuming
                // afterwards. Without this guard the resumed iteration writes
                // `state = .open` over `stop()`'s `.idle`, or yields an event
                // to subscribers, *after* the connection was stopped — and no
                // loop is left running to correct it, so a stopped connection
                // reports itself connected forever.
                guard !Task.isCancelled else { return }
                guard case .event(let event) = element else { continue }

                switch event.kind {
                case .open:
                    state = .open
                    attempt = 0
                case .message:
                    record(event)
                    continuation.yield(event)
                case .keepalive, .pollRequest, nil:
                    continue
                }
            }
        } catch {
            if !Task.isCancelled { await watchdog.stop() }
            throw error
        }
        if !Task.isCancelled { await watchdog.stop() }
    }

    private func record(_ event: NtfyEvent) {
        guard let index = watermarks.firstIndex(where: { $0.topic == event.topic }) else { return }
        let existing = watermarks[index].lastMessageTime
        guard existing == nil || event.date > existing! else { return }
        watermarks[index] = TopicWatermark(topic: event.topic, lastMessageTime: event.date)
    }

    private func handleWatchdogTimeout() {
        // `runTask == nil` means stopped, and a fire that was already in flight
        // when that happened must not resurrect the connection. This actor is
        // reentrant across `stop()`'s `await watchdog.stop()`: a watchdog fire
        // that had already passed its own guards can run this method in that
        // window, and without this check it would install a fresh run loop that
        // `stop()` then never clears — leaving `state == .idle` while a live
        // loop reconnects forever, with nothing reporting it.
        //
        // The condition is exact, not defensive: every path that starts a run
        // loop assigns `runTask`, and only `stop()` clears it, while the
        // watchdog holds a handler at all only because some `connectOnce`
        // armed it — which implies a live `runTask`.
        guard runTask != nil else { return }

        state = .degraded(reason: "no keepalive within timeout")
        runTask?.cancel()
        runTask = Task { await self.runLoop() }
    }

    private func waitBeforeRetry() async {
        attempt += 1
        state = .backoff(attempt: attempt)
        let delay = backoff.delay(forAttempt: attempt, randomFraction: { Double.random(in: 0...1) })
        // Same reasoning as the rate-limited sleep above: a cancelled backoff
        // means this loop was superseded, and nothing may run after it.
        do {
            try await sleeper.sleep(for: delay)
        } catch {
            return
        }
    }
}
