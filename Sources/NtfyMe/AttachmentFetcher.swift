import Foundation
import NtfyKit

/// Downloads the attachments of messages that have just been stored, and
/// records where each file landed.
///
/// Runs off `Ingest`'s stored-batch hook, which is the only place that knows
/// which events were *newly written* — a reconnect replays messages, and
/// re-downloading a file the archive already has would waste bandwidth on
/// every reconnect.
///
/// **Deliberately detached from the hook that starts it.** That hook runs
/// inside the flush that stored the batch, and a download can take seconds
/// against an attacker-chosen host. Blocking there would hold up the
/// notification for the same batch and stall the connection's pump behind a
/// remote server's response time. So each batch is handed to a task this
/// actor owns — owned rather than forgotten, so `stop()` can cancel it and
/// nothing is still writing to the store after the graph has shut down.
actor AttachmentFetcher {
    private let store: MessageStore
    private let downloader: AttachmentDownloader
    private var inFlight: Set<Task<Void, Never>> = []
    private var isStopping = false

    init(store: MessageStore, directory: URL) {
        self.store = store
        self.downloader = AttachmentDownloader(directory: directory)
    }

    /// Downloads anything in this batch that carries an attachment. Returns
    /// immediately; the work happens in a task this actor owns.
    func fetchAttachments(for events: [NtfyEvent], serverID: UUID) {
        guard !isStopping else { return }
        let withAttachments = events.filter { $0.attachment != nil }
        guard !withAttachments.isEmpty else { return }

        let task = Task { [weak self] in
            // Serially, not concurrently: a batch can be a whole replay
            // window, and firing every download at once would open dozens of
            // connections to a host the message chose. There is no deadline
            // pressure here — nothing is waiting on these.
            for event in withAttachments {
                if Task.isCancelled { return }
                await self?.download(event, serverID: serverID)
            }
        }
        inFlight.insert(task)
        Task { [weak self] in
            await task.value
            await self?.forget(task)
        }
    }

    private func forget(_ task: Task<Void, Never>) {
        inFlight.remove(task)
    }

    private func download(_ event: NtfyEvent, serverID: UUID) async {
        guard let attachment = event.attachment else { return }
        do {
            let filename = try await downloader.download(attachment)
            let key = Message.uniqueKey(serverID: serverID, topic: event.topic,
                                        messageID: event.id)
            // A no-op if the message was pruned or deleted while the download
            // was in flight, which is not a caller error — see the store's
            // own doc comment.
            try await store.setAttachmentLocalFilename(filename, forMessage: key)
        } catch {
            // Domain and code only. An attachment error can carry the
            // attacker-chosen URL or the server-supplied filename, and
            // `Log.swift` bars both as message content. The message itself is
            // already archived; only its file is missing, and the History
            // window shows the metadata either way.
            let ns = error as NSError
            Log.app.error("attachment download failed for server \(serverID.uuidString, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }

    /// Cancels every download still running and waits for them to unwind, so
    /// nothing is still writing to the store once this returns — the same
    /// contract `ConnectionCoordinator.stop()` gives for its pumps.
    func stop() async {
        isStopping = true
        let tasks = inFlight
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        inFlight.removeAll()
    }
}
