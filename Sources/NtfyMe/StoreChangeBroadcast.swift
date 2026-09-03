import Foundation

/// One place for "the store changed; anything displaying it should catch up."
///
/// There is no change stream out of `MessageStore` — every surface in this
/// app pulls (see `MenuBarController`'s doc comment) — so a write made on one
/// surface is invisible to every other until something tells it to re-read.
/// Four separate bugs of exactly that shape reached a user before this type
/// existed, each fixed with its own point-to-point closure from the writer to
/// the one reader that had gone stale:
///
/// 1. The menu bar badge, stale until the next 30-second timer tick, fixed
///    with `AppGraph.onStoredBatch`.
/// 2. The connection state after `ConnectionCoordinator.sync()`.
/// 3. A topic's mute state, written in Settings, still showing the old
///    bell-slash in the History sidebar.
/// 4. A topic *added* in Settings, absent from the History sidebar entirely
///    while its messages were arriving in the list beside it — reported from
///    a screenshot of the running app, and the one that made the pattern's
///    cost obvious: fix #3 had shipped days earlier and did nothing for it,
///    because it was wired to one store method rather than to the idea of a
///    write.
///
/// The fifth closure would have been `addTopic`'s, then `removeTopic`'s, then
/// `addServer`'s, each one a separate commit after a separate bug report. So
/// instead: writers `post()`, readers `observe`, and neither knows the other
/// exists. Adding a surface means one `observe` at wiring time; adding a
/// write means one `post()` — and forgetting either is a whole-surface
/// staleness that shows up immediately, not a single field that looks right
/// until someone happens to change it.
///
/// Deliberately not `Notification`/`NotificationCenter`: observers here are
/// `async` closures that must be awaited, so `post()` returns only once every
/// surface has finished re-reading — which is what makes it testable without
/// polling, and what lets a caller sequence a refresh against anything else
/// it does. It is also, unlike a notification name, impossible to typo.
@MainActor
final class StoreChangeBroadcast {
    private var observers: [() async -> Void] = []

    /// Registers a surface to re-read on every `post()`. Never unregistered:
    /// this app's surfaces are created once at launch and live as long as the
    /// app delegate does. Callers still capture weakly, so an observer whose
    /// surface *is* torn down becomes a no-op rather than resurrecting it —
    /// see `AppDelegate.applicationDidFinishLaunching`.
    func observe(_ refresh: @escaping () async -> Void) {
        observers.append(refresh)
    }

    /// Tells every registered surface to re-read, and returns once they have.
    ///
    /// Sequential rather than a task group: both of today's observers are
    /// `@MainActor` and would serialise on this actor anyway, and a
    /// deterministic order keeps a failure — every observer swallows its own,
    /// none can throw here — from depending on scheduling.
    func post() async {
        for refresh in observers {
            await refresh()
        }
    }
}
