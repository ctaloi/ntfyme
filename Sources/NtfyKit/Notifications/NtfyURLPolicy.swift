import Foundation

/// The one place that decides whether a URL from a message is safe to open.
///
/// A message is attacker-controlled: on public ntfy.sh anyone who knows a
/// topic name can publish to it (spec §9 — a topic name is effectively a
/// password). So `file://`, a custom app scheme, or anything else that is
/// not plain web traffic must never reach `NSWorkspace.open`/`openURL` —
/// `file://` reads local files, and a custom scheme can launch another app.
/// Restricting to the schemes a browser would treat as ordinary web content
/// removes both.
///
/// This is `public` specifically so every app-target call site that opens a
/// message-derived URL — the menu bar popover, the History window, a
/// notification's click/attachment/action URLs — goes through the same
/// rule. Before this existed, `NotificationDecision`'s equivalent check was
/// `private`, which meant no app-target code could reach it: three
/// divergent copies of the same security rule were starting to form because
/// sharing the correct one was impossible. Route everything through here
/// instead of writing a new copy.
public enum NtfyURLPolicy {
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// Returns the URL only if it parses and its scheme is allowed.
    public static func sanitized(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme)
        else { return nil }
        return url
    }
}
