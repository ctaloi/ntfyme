import Foundation
import NtfyKit

/// Runs retention at launch and daily thereafter (spec §8).
actor RetentionScheduler {
    private let store: MessageStore
    /// Re-read on every pass rather than captured once at `init` as a plain
    /// `RetentionPolicy` — this scheduler lives for the whole app run, so a
    /// value captured once would freeze whatever retention was set at
    /// launch. A change made in Settings must reach the very next prune, not
    /// wait for a relaunch to reconstruct this actor with a fresh value.
    private let policyProvider: @Sendable () -> RetentionPolicy
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(store: MessageStore, policyProvider: @escaping @Sendable () -> RetentionPolicy,
         interval: Duration = .seconds(86_400)) {
        self.store = store
        self.policyProvider = policyProvider
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.pruneNow()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.interval)
                } catch {
                    // Cancelled: stop scheduling. A `try?` here would swallow
                    // the cancellation and keep the loop spinning.
                    return
                }
                await self.pruneNow()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func pruneNow() async {
        do {
            let result = try await store.prune(policy: policyProvider(), attachmentsDirectory: attachmentsDirectory())
            Log.store.info("pruned \(result.messagesDeleted, privacy: .public) messages, \(result.attachmentFilesDeleted, privacy: .public) files")
        } catch {
            let ns = error as NSError
            Log.store.error("prune failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }

    /// Delegates to `AppGraph.attachmentsDirectory()` rather than repeating
    /// the literal. This function used to compute the path itself, with a
    /// comment warning that whoever added a real consumer had to match it
    /// exactly or `prune` would silently delete nothing forever. Two
    /// consumers now exist — the downloader and the History window's Quick
    /// Look — so the warning is retired in favour of there being one
    /// definition to agree with.
    private func attachmentsDirectory() -> URL? {
        AppGraph.attachmentsDirectory()
    }
}
