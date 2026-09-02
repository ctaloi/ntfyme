import Foundation
import Testing
@testable import NtfyKit

/// `NotificationDecision.presentableActions(from:)` is `public` specifically
/// so app-target UI (e.g. the History window's action buttons) can render
/// actions without duplicating the security rules `decide(...)` already
/// applies. These tests call it directly, not through `decide`, to pin that
/// the public entry point itself — not just the internal path `decide` used
/// before it was exposed — drops what it should.
@Test func presentableActionsPublicAPIDropsBroadcastAndBadSchemeView() {
    let actions: [NtfyAction] = [
        NtfyAction(id: "a1", action: "view", label: "Safe", clear: nil,
                   url: "https://example.com/x", method: nil, headers: nil, body: nil,
                   value: nil, intent: nil, extras: nil),
        NtfyAction(id: "a2", action: "broadcast", label: "Tasker", clear: nil,
                   url: nil, method: nil, headers: nil, body: nil,
                   value: nil, intent: "com.example", extras: nil),
        NtfyAction(id: "a3", action: "view", label: "Local file", clear: nil,
                   url: "file:///etc/passwd", method: nil, headers: nil, body: nil,
                   value: nil, intent: nil, extras: nil),
    ]

    let presentable = NotificationDecision.presentableActions(from: actions)
    #expect(presentable.map(\.id) == ["a1"])
}
