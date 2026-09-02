import Foundation

/// Indirection over `Task.sleep` so timeouts are tested deterministically
/// rather than by waiting out real seconds.
public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemSleeper: Sleeper {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Test sleeper: every `sleep` suspends until `advanceOnePendingSleep()` is called.
///
/// `waitForPendingSleep()` exists to remove a start-order race: the watchdog
/// arms its timer inside a detached `Task`, so a test that advances the sleeper
/// immediately after `start()` can run before any sleep has been registered,
/// advance nothing, and hang. Always wait before advancing.
public actor ManualSleeper: Sleeper {
    private var pending: [CheckedContinuation<Void, Error>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            let toWake = waiters
            waiters.removeAll()
            toWake.forEach { $0.resume() }
        }
    }

    /// Suspends until at least one sleep is registered.
    public func waitForPendingSleep() async {
        guard pending.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Releases the oldest pending sleep, if any.
    public func advanceOnePendingSleep() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }
}

/// Fires when no line — message *or* keepalive — has arrived within `timeout`.
///
/// ntfy sends a keepalive roughly every 45s, so the default 90s timeout allows
/// one to be missed before the connection is declared dead.
public actor KeepaliveWatchdog {
    private let timeout: Duration
    private let sleeper: Sleeper

    private var generation = 0
    private var task: Task<Void, Never>?

    public init(timeout: Duration = .seconds(90), sleeper: Sleeper = SystemSleeper()) {
        self.timeout = timeout
        self.sleeper = sleeper
    }

    public func start(onTimeout: @Sendable @escaping () async -> Void) {
        stop()
        arm(onTimeout: onTimeout)
    }

    /// Called for every received line. Restarts the countdown.
    public func pet() {
        guard let handler = currentHandler else { return }
        generation += 1
        task?.cancel()
        arm(onTimeout: handler)
    }

    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        currentHandler = nil
    }

    private var currentHandler: (@Sendable () async -> Void)?

    private func arm(onTimeout: @Sendable @escaping () async -> Void) {
        currentHandler = onTimeout
        let armed = generation
        task = Task { [timeout, sleeper] in
            do { try await sleeper.sleep(for: timeout) } catch { return }
            await self.fireIfStillArmed(armed)
        }
    }

    private func fireIfStillArmed(_ armed: Int) async {
        guard armed == generation, let handler = currentHandler else { return }
        await handler()
    }
}
