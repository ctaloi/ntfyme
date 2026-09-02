import Foundation
import NtfyKit

/// Runs retention at launch and daily thereafter (spec §8).
actor RetentionScheduler {
    private let store: MessageStore
    private let policy: RetentionPolicy
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(store: MessageStore, policy: RetentionPolicy, interval: Duration = .seconds(86_400)) {
        self.store = store
        self.policy = policy
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
            let result = try await store.prune(policy: policy, attachmentsDirectory: attachmentsDirectory())
            Log.store.info("pruned \(result.messagesDeleted, privacy: .public) messages, \(result.attachmentFilesDeleted, privacy: .public) files")
        } catch {
            let ns = error as NSError
            Log.store.error("prune failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }

    /// No attachment downloader exists yet in this plan, so this path is
    /// unverified against a real consumer. Whoever adds one must use this
    /// exact literal (`Application Support/dev.aloi.NtfyMe/Attachments`) —
    /// disagreement here would make `prune` silently delete nothing forever.
    private func attachmentsDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appending(path: "dev.aloi.NtfyMe/Attachments")
    }
}
