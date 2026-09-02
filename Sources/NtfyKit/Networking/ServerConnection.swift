import Foundation

/// Owns one long-lived connection to one server, covering every subscribed
/// topic on that server (spec §5).
public actor ServerConnection {
    public private(set) var state: ConnectionState = .idle
    /// Server timestamp of the most recent **keepalive** line. A keepalive is
    /// the one line that proves the server has delivered everything up to that
    /// point on every subscribed topic, which is what makes §5.2's resume rule
    /// correct.
    ///
    /// Deliberately not "the most recent line of any kind". ntfy's subscribe
    /// handler calls `sub(v, NewOpenMessage(...))` and only *then*
    /// `sendOldMessages(...)`, so the `open` line — which carries `time = now`
    /// — is sent *before* the replay it precedes. Advancing on `open` moved
    /// the resume point past every message the replay had not yet sent, and a
    /// drop mid-replay then meant nothing ever asked for them again. Messages
    /// do not qualify either: `sendOldMessages` walks the subscribed topics one
    /// at a time rather than merging them in time order, so a message's
    /// timestamp says nothing about how far the *other* topics have been
    /// delivered. Keepalives are emitted only after `sendOldMessages` returns,
    /// which is precisely what makes them the proof.
    public private(set) var caughtUpTo: Date?

    private let endpoint: NtfyEndpoint
    private let topics: [String]
    private var watermarks: [TopicWatermark]
    private let client: any StreamClient
    private let backoff: BackoffPolicy
    private let sleeper: Sleeper
    private let watchdog: KeepaliveWatchdog
    private let cacheWindow: TimeInterval

    private var runTask: Task<Void, Never>?
    private var attempt = 0
    /// Set when the server rejects the `since` this client built, consumed by
    /// the next `connectOnce`. Spec §10: the malformed value must not be
    /// retried, so the next attempt asks for `since=all` instead.
    private var forceSinceAll = false

    /// Created eagerly in `init`, not lazily on first access. A lazy stream
    /// leaves `continuation` nil until something reads `events`, so any message
    /// arriving before the first read is silently dropped — and whether that
    /// happens depends on task scheduling. `AsyncStream` buffers by default, so
    /// an eager stream loses nothing.
    ///
    /// **This carries keepalives as well as messages, in stream order.** A
    /// consumer that wants content must filter on `kind == .message` — as
    /// `MessageStore.insert` already does. The keepalives are here because
    /// they are the only line that proves delivery (§5.2), and a consumer that
    /// persists resume state has to know *where in this sequence* that proof
    /// fell: reading `caughtUpTo` off this actor instead is a separate,
    /// unordered channel, and a value read from it can already have advanced
    /// past events still sitting in the consumer's own buffer. Putting the
    /// proof in the stream is what makes "everything before this keepalive is
    /// in my hands" a fact rather than a hope. `open` is deliberately *not*
    /// yielded: it precedes the replay it announces and proves nothing.
    private let continuation: AsyncStream<NtfyEvent>.Continuation
    public nonisolated let events: AsyncStream<NtfyEvent>

    /// One-shot facts a level-triggered `state` cannot carry — see
    /// `ConnectionDiagnostic`. Created eagerly for the same reason `events`
    /// is: a lazily-created stream leaves its continuation nil until
    /// something first reads it, silently dropping anything emitted before
    /// that.
    ///
    /// Bounded, unlike `events`. Nothing consumes this until the UI lands, and
    /// a server emitting malformed lines yields a `.skippedLine` for each one,
    /// so an unbounded buffer would grow for the life of the process against a
    /// consumer that may never arrive. The newest 64 are what a status surface
    /// would show anyway; `events` stays unbounded because losing a message is
    /// not a display concern, and it has a consumer.
    private let diagnosticContinuation: AsyncStream<ConnectionDiagnostic>.Continuation
    public nonisolated let diagnostics: AsyncStream<ConnectionDiagnostic>

    /// `topics` is derived from `watermarks` rather than passed alongside it.
    /// They were two inputs to one truth, and they could disagree: a topic
    /// present in `topics` but absent from `watermarks` was subscribed to on
    /// the wire, while `record` silently dropped every message it produced,
    /// so that topic never advanced its resume point and replayed on every
    /// reconnect. A subscription with no watermark yet is represented by a
    /// `TopicWatermark` whose `lastMessageTime` is `nil`.
    ///
    /// `caughtUpTo` seeds the resume point from the store (`Server.caughtUpTo`,
    /// written by `Ingest`). Without it the property could only ever start
    /// `nil`, so §5.2's `max(min(watermarks), caughtUpTo)` collapsed back to
    /// the pre-§5.2 `min(watermarks)` on every launch — and a topic that had
    /// merely been quiet for longer than the cache window produced a
    /// full-cache replay and a false history gap every time the app started,
    /// which is the exact defect §5.2 exists to remove.
    public init(
        endpoint: NtfyEndpoint,
        watermarks: [TopicWatermark],
        caughtUpTo: Date? = nil,
        client: any StreamClient = NtfyStreamClient(),
        backoff: BackoffPolicy = .standard,
        sleeper: Sleeper = SystemSleeper(),
        watchdogTimeout: Duration = .seconds(90),
        cacheWindow: TimeInterval = 12 * 3600
    ) {
        var capturedContinuation: AsyncStream<NtfyEvent>.Continuation!
        self.events = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation

        var capturedDiagnostics: AsyncStream<ConnectionDiagnostic>.Continuation!
        self.diagnostics = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
            capturedDiagnostics = $0
        }
        self.diagnosticContinuation = capturedDiagnostics

        self.endpoint = endpoint
        self.topics = watermarks.map(\.topic)
        self.watermarks = watermarks
        self.caughtUpTo = caughtUpTo
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
                // `connectOnce`'s catch already stopped the watchdog on every
                // path that reaches here, so a second `await watchdog.stop()`
                // is redundant — and it was worse than redundant: it is a
                // suspension point in the middle of what is otherwise an
                // atomic tail, which is what makes clearing `runTask` below
                // safe against a concurrent `reconnectNow()`.
                //
                // Clearing the handle matters because `start()` guards on
                // `runTask == nil`: leaving a finished task in place made every
                // future `start()` a silent no-op, so a server whose token the
                // user had just fixed could never be restarted. A public method
                // that ignores its caller is exactly what this project forbids.
                //
                // Safe against `reconnectNow()` installing a replacement: that
                // path cancels this task first, the guard above observes it,
                // and there is no suspension point between the guard and here.
                runTask = nil
                diagnosticContinuation.yield(.unauthorized)
                return
            } catch NtfyStreamClient.Error.rateLimited(let retryAfter) {
                guard !Task.isCancelled else { return }
                degrade(.rateLimited)
                // An explicit `catch { return }` rather than `try?` — but not
                // for the cancellation case, which an earlier version of this
                // comment claimed. On cancellation `try?` falls to the end of
                // the catch, then to the end of the `do`/`catch`, then to the
                // loop condition, which is already false: identical behavior,
                // no second connect attempt.
                //
                // The real distinction is a *non-cancellation* error, which a
                // custom `Sleeper` may throw. `try?` would swallow it and go
                // straight back to connecting; this kills the loop instead of
                // spinning against a sleeper that cannot sleep.
                do {
                    try await sleeper.sleep(for: .seconds(Int(retryAfter ?? 60)))
                } catch {
                    return
                }
            } catch NtfyStreamClient.Error.invalidSince {
                guard !Task.isCancelled else { return }
                // Spec §10: a client bug, not a server condition. Without this
                // branch the error falls into the generic one below, backs off,
                // reconnects, and the resolver produces the same rejected
                // `since` — forever. Log loudly and fall back to `since=all`.
                Log.connection.error(
                    "server rejected the since parameter (HTTP 400); falling back to since=all"
                )
                forceSinceAll = true
                degrade(.invalidSince)
                diagnosticContinuation.yield(.invalidSinceRejected)
                await waitBeforeRetry()
            } catch {
                guard !Task.isCancelled else { return }
                degrade(.classify(error))
                await waitBeforeRetry()
            }
        }
    }

    private func connectOnce() async throws {
        state = .connecting

        let since: SinceParameter
        if forceSinceAll {
            // Read here but cleared only past the cancellation guard below. If
            // it were consumed here, an attempt abandoned before it reached the
            // wire — a `stop()` landing on the watchdog hop, or a throwing
            // `streamRequest` — would discard the fallback without ever having
            // sent `since=all`, and the next loop would rebuild the rejected
            // value and earn another 400. Exactly the seam this fix exists to
            // close, so it must not be reintroduced by the fix.
            since = .all
        } else {
            let resolution = WatermarkResolver.resolve(
                watermarks: watermarks,
                caughtUpTo: caughtUpTo,
                cacheWindow: cacheWindow
            )
            since = resolution.since
            if resolution.hasHistoryGap {
                // Surfaced rather than swallowed: the server will replay its
                // whole cache and some messages are simply unrecoverable
                // (spec §10), and that must never look like a clean resume.
                //
                // The log is the durable half of "surfaced". The state write
                // below is still a one-shot value in a level-triggered enum —
                // the first line on the stream replaces it with `.open` tens
                // of milliseconds later — so the diagnostic below is what a
                // consumer actually latches onto; `degrade` here only drives
                // the menu bar icon for the brief window before `.open`. The
                // resume point this gap is measured from is no longer the
                // naive `min(watermarks)`: spec §5.2's
                // `max(min(watermarks), caughtUpTo)` is implemented above, so
                // a merely quiet topic no longer reports a gap that did not
                // happen.
                Log.connection.notice(
                    "history gap: resume watermark predates the server cache window; the server will replay its cache"
                )
                degrade(.historyGap)
                // `hasHistoryGap` is only ever true alongside `since` resolved
                // to `.unixTime` — the `.all` branch above always pairs with
                // `hasHistoryGap: false`, and there is no other case. Matched
                // rather than force-unwrapped so a future resolver change that
                // breaks the invariant silently drops the diagnostic instead
                // of crashing the connection.
                if case .unixTime(let seconds) = since {
                    diagnosticContinuation.yield(.historyGap(since: Date(timeIntervalSince1970: TimeInterval(seconds))))
                }
            }
        }

        let request = try endpoint.streamRequest(topics: topics, since: since)

        await watchdog.start { [weak self] in
            await self?.handleWatchdogTimeout()
        }

        // Arming the watchdog is a cross-actor hop, so `stop()` or
        // `reconnectNow()` can run to completion while this loop is suspended
        // on it. Without this guard the loop resumes and calls
        // `client.stream(request)`, which issues a real HTTP request before the
        // cancelled loop's first `next()` gets a chance to tear it down — one
        // stray connect to the server per stop.
        //
        // It deliberately does *not* stop the watchdog on the way out, for the
        // same reason both exits below are guarded: the loop that replaced this
        // one may already own the arm.
        guard !Task.isCancelled else { return }

        // Past every point that could abandon this attempt, so the fallback is
        // spent only on one that actually reaches the wire. Once spent, a later
        // attempt resumes normal watermark resolution.
        forceSinceAll = false

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

                guard case .event(let event) = element else {
                    if case .skippedLine(let reason) = element {
                        // Spec §10: log, skip the line, keep the stream alive.
                        // `reason` comes from `NtfyEventDecoder`'s closed
                        // vocabulary and never quotes the line, which is what
                        // makes `.public` safe here (spec §9).
                        Log.stream.warning("skipped line: \(reason, privacy: .public)")
                        diagnosticContinuation.yield(.skippedLine(reason: reason))
                    }
                    continue
                }

                switch event.kind {
                case .open:
                    state = .open
                    attempt = 0
                case .message:
                    record(event)
                    continuation.yield(event)
                case .keepalive:
                    // §5.2, and the only place `caughtUpTo` moves. See the
                    // property's doc comment for why `open` and `message`
                    // lines are deliberately excluded. The `time > 0` guard
                    // stays: a line with no usable server clock must not
                    // rewind the resume point to 1970.
                    if event.time > 0 {
                        let lineTime = event.date
                        if caughtUpTo == nil || lineTime > caughtUpTo! { caughtUpTo = lineTime }
                    }
                    // Yielded downstream too, in stream order, so a consumer
                    // persisting resume state can tie the proof to its own
                    // batch instead of reading `caughtUpTo` across the actor
                    // boundary and getting a value that has already moved past
                    // events it is still holding. See `events`' doc comment.
                    continuation.yield(event)
                case .pollRequest, nil:
                    continue
                }
            }
        } catch {
            if !Task.isCancelled { await watchdog.stop() }
            throw error
        }
        if !Task.isCancelled { await watchdog.stop() }
    }

    /// Watermarks as currently known, for persistence and for rebuilding the
    /// connection after a topic is added. Previously write-only.
    public func watermarkSnapshot() -> [TopicWatermark] { watermarks }

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
        // This guard is load-bearing rather than a restatement of an invariant
        // that already holds. An earlier version of this comment claimed that
        // the watchdog holding a handler at all implies a live `runTask`,
        // because only a `connectOnce` arms it. That is false: `stop()`'s
        // `await watchdog.stop()` and a run loop's `await watchdog.start` can
        // both be queued on the watchdog actor and run in that order, leaving a
        // handler armed after `stop()` has returned. `runTask` is also cleared
        // by the unauthorized branch now, not only by `stop()`. What does hold,
        // and is all this needs, is the converse: a live run loop always has a
        // non-nil handle.
        guard runTask != nil else { return }

        degrade(.keepaliveTimeout)
        runTask?.cancel()
        runTask = Task { await self.runLoop() }
    }

    /// The one place `.degraded` is written, so every degradation is logged
    /// and none can carry a free-form string.
    private func degrade(_ reason: DegradedReason) {
        Log.connection.warning("connection degraded: \(reason.logLabel, privacy: .public)")
        state = .degraded(reason: reason)
    }

    private func waitBeforeRetry() async {
        attempt += 1
        state = .backoff(attempt: attempt)
        let delay = backoff.delay(forAttempt: attempt, randomFraction: { Double.random(in: 0...1) })
        // Written for symmetry with the rate-limited sleep above, not because
        // it changes anything here: `catch { return }` is this function's final
        // statement, so it is provably identical to `try?` on every path,
        // cancelled or not. Kept so the two sleeps read the same way and so
        // adding a statement after this one cannot silently acquire a
        // fall-through the author did not intend.
        do {
            try await sleeper.sleep(for: delay)
        } catch {
            return
        }
    }
}
