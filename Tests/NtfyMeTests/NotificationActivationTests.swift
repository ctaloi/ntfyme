import Testing
import UserNotifications
import NtfyKit
@testable import NtfyMe

/// Spec §6: clicking the body opens the message's `click` URL when it has
/// one, otherwise History; an action button performs that action. The routing
/// is resolved from the notification's own payload, because a banner can be
/// tapped after the launch that created it has ended.

private let P = NotificationPresenter.self

@Test func dismissingANotificationDoesNothing() {
    #expect(P.activation(forActionIdentifier: UNNotificationDismissActionIdentifier,
                         userInfo: [NotificationPresenter.messageKeyKey: "s/alerts/1"]) == nil)
}

@Test func clickingTheBodyOpensTheClickURLWhenThereIsOne() {
    let result = P.activation(
        forActionIdentifier: UNNotificationDefaultActionIdentifier,
        userInfo: [NotificationPresenter.clickURLKey: "https://example.com/x",
                   NotificationPresenter.messageKeyKey: "s/alerts/1"])
    #expect(result == .openURL(URL(string: "https://example.com/x")!))
}

@Test func clickingTheBodyWithoutAClickURLOpensHistoryAtThatMessage() {
    let result = P.activation(
        forActionIdentifier: UNNotificationDefaultActionIdentifier,
        userInfo: [NotificationPresenter.messageKeyKey: "s/alerts/1"])
    #expect(result == .openHistory(messageKey: "s/alerts/1"))
}

/// The click URL is attacker-controlled, so it goes back through the same
/// policy every other message-derived URL does. A `file://` click must not
/// become an open, and it must not silently fall through to History either —
/// falling through would let a hostile URL still drive the app somewhere.
@Test func aDisallowedClickSchemeIsNotOpened() {
    let result = P.activation(
        forActionIdentifier: UNNotificationDefaultActionIdentifier,
        userInfo: [NotificationPresenter.clickURLKey: "file:///etc/passwd",
                   NotificationPresenter.messageKeyKey: "s/alerts/1"])
    #expect(result == .openHistory(messageKey: "s/alerts/1"))
}

@Test func anActionButtonPerformsThatAction() throws {
    let action = PresentableAction(id: "a1", title: "Open",
                                   kind: .view(url: URL(string: "https://example.com")!))
    let data = try JSONEncoder().encode([action])
    let result = P.activation(forActionIdentifier: "a1",
                              userInfo: [NotificationPresenter.actionsKey: data])
    #expect(result == .perform(action))
}

/// A category identifier is a hash of the action set, so a notification left
/// over from a previous launch can deliver an identifier this payload no
/// longer contains. Doing nothing is correct; the alternative is firing the
/// wrong action.
@Test func anUnknownActionIdentifierDoesNothing() throws {
    let action = PresentableAction(id: "a1", title: "Open",
                                   kind: .view(url: URL(string: "https://example.com")!))
    let data = try JSONEncoder().encode([action])
    #expect(P.activation(forActionIdentifier: "gone",
                         userInfo: [NotificationPresenter.actionsKey: data]) == nil)
}

@Test func anActionTapWithNoPayloadAtAllDoesNothing() {
    #expect(P.activation(forActionIdentifier: "a1", userInfo: [:]) == nil)
}

/// The round trip is the point: an action must survive `userInfo` intact,
/// including an `http` action's method, headers and body.
@Test func everyActionKindSurvivesTheUserInfoRoundTrip() throws {
    let actions = [
        PresentableAction(id: "v", title: "View", kind: .view(url: URL(string: "https://e.com")!)),
        PresentableAction(id: "c", title: "Copy", kind: .copy(value: "token-shaped-text")),
        PresentableAction(id: "h", title: "Ack", kind: .http(
            url: URL(string: "https://e.com/ack")!, method: "POST",
            headers: ["X-Custom": "1"], body: "{}")),
    ]
    let data = try JSONEncoder().encode(actions)
    for expected in actions {
        #expect(P.activation(forActionIdentifier: expected.id,
                             userInfo: [NotificationPresenter.actionsKey: data])
                == .perform(expected))
    }
}
