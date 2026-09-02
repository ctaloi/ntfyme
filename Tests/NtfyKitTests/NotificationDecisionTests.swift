import Foundation
import Testing
@testable import NtfyKit

private func message(priority: Int?, topic: String = "alerts",
                     title: String? = "T", body: String = "B",
                     actions: String = "") -> NtfyEvent {
    let p = priority.map { "\"priority\":\($0)," } ?? ""
    let t = title.map { "\"title\":\"\($0)\"," } ?? ""
    let a = actions.isEmpty ? "" : "\"actions\":\(actions),"
    let json = """
    {"id":"m1","time":1788353322,"event":"message","topic":"\(topic)",\(p)\(t)\(a)"message":"\(body)"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private let unmuted = TopicAlertSettings(muted: false, minAlertPriority: 1)
private let sid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

@Test func priorityMapsToInterruptionPerSpec() {
    func level(_ p: Int) -> NotificationInterruption? {
        guard case .present(let r) = NotificationDecision.decide(
            event: message(priority: p), serverID: sid,
            settings: unmuted, preferences: .default) else { return nil }
        return r.interruption
    }
    #expect(level(1) == .passive)
    #expect(level(2) == .passive)
    #expect(level(3) == .active)
    #expect(level(4) == .timeSensitive)
    #expect(level(5) == .timeSensitive)
}

@Test func onlyPriorityThreeAndAboveMakesASound() {
    func sound(_ p: Int) -> Bool? {
        guard case .present(let r) = NotificationDecision.decide(
            event: message(priority: p), serverID: sid,
            settings: unmuted, preferences: .default) else { return nil }
        return r.playsSound
    }
    #expect(sound(1) == false)
    #expect(sound(2) == false)
    #expect(sound(3) == true)
    #expect(sound(5) == true)
}

@Test func threadIdentifierGroupsPerServerAndTopic() {
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, topic: "deploys"), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    #expect(r.threadIdentifier == "\(sid.uuidString)/deploys")
}

@Test func aMutedTopicIsSuppressed() {
    let d = NotificationDecision.decide(
        event: message(priority: 5), serverID: sid,
        settings: TopicAlertSettings(muted: true, minAlertPriority: 1),
        preferences: .default)
    #expect(d == .suppress(.topicMuted))
}

@Test func aMessageBelowTheTopicThresholdIsSuppressed() {
    let d = NotificationDecision.decide(
        event: message(priority: 2), serverID: sid,
        settings: TopicAlertSettings(muted: false, minAlertPriority: 4),
        preferences: .default)
    #expect(d == .suppress(.belowTopicThreshold))
}

@Test func theGlobalRecordOnlyToggleSuppressesEverything() {
    var prefs = Preferences.default
    prefs.recordOnlyNeverAlert = true
    let d = NotificationDecision.decide(
        event: message(priority: 5), serverID: sid, settings: unmuted, preferences: prefs)
    #expect(d == .suppress(.globallySilenced))
}

@Test func keepaliveAndOpenNeverNotify() throws {
    let open = try Fixtures.decode(Fixtures.openEvent)
    let keepalive = try Fixtures.decode(Fixtures.keepaliveEvent)
    #expect(NotificationDecision.decide(event: open, serverID: sid,
                                        settings: unmuted, preferences: .default)
            == .suppress(.notAMessage))
    #expect(NotificationDecision.decide(event: keepalive, serverID: sid,
                                        settings: unmuted, preferences: .default)
            == .suppress(.notAMessage))
}

/// broadcast is Android-only; showing it as a button that does nothing is worse
/// than omitting it.
@Test func broadcastActionsAreDroppedAndTheOthersSurvive() {
    let actions = """
    [{"id":"a1","action":"view","label":"Open","url":"https://example.com/x"},
     {"id":"a2","action":"broadcast","label":"Tasker","intent":"com.example"},
     {"id":"a3","action":"copy","label":"Copy","value":"abc"}]
    """
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, actions: actions), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    #expect(r.actions.map(\.id) == ["a1", "a3"])
    #expect(r.actions.first?.title == "Open")
}

/// ntfy allows at most three; more than that is a malformed message, and a
/// silently truncated button list is better than a rejected message.
@Test func atMostThreeActionsSurvive() {
    let actions = (1...5).map {
        "{\"id\":\"a\($0)\",\"action\":\"copy\",\"label\":\"L\($0)\",\"value\":\"v\"}"
    }.joined(separator: ",")
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, actions: "[\(actions)]"), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    #expect(r.actions.count == 3)
}

/// The category id must be stable for the same action shape and different for a
/// different one, or macOS reuses the wrong buttons.
@Test func categoryIdentifierIsStableForTheSameActionSet() {
    func categoryID(_ actions: String) -> String? {
        guard case .present(let r) = NotificationDecision.decide(
            event: message(priority: 3, actions: actions), serverID: sid,
            settings: unmuted, preferences: .default) else { return nil }
        return r.categoryIdentifier
    }
    let one = """
    [{"id":"x","action":"copy","label":"Copy","value":"v"}]
    """
    let two = """
    [{"id":"y","action":"view","label":"Open","url":"https://example.com/x"}]
    """
    #expect(categoryID(one) == categoryID(one))
    #expect(categoryID(one) != categoryID(two))
    #expect(categoryID("") == nil)   // no actions, no category
}

@Test func aMessageWithNoTitleUsesTheTopicAsTheTitle() {
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, topic: "deploys", title: nil), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    #expect(r.title == "deploys")
    #expect(r.body == "B")
}
