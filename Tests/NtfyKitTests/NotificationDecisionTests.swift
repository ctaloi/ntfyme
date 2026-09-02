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

// MARK: - Security: topics are effectively passwords on public ntfy.sh (spec §9),
// so every action URL, method, header, and copy value below is attacker input.

/// `file://` would let a message read a local file via the button's target;
/// restricting to http/https removes that without losing the button entirely
/// for a well-formed sibling action.
@Test func aViewActionWithAnUnsupportedSchemeIsDroppedAndOthersSurvive() {
    let actions = """
    [{"id":"a1","action":"view","label":"Local","url":"file:///etc/passwd"},
     {"id":"a2","action":"view","label":"Safe","url":"https://example.com/x"}]
    """
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, actions: actions), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    #expect(r.actions.map(\.id) == ["a2"])
}

/// The click URL is optional on `NotificationRequest`, so an unsafe scheme
/// there nulls the click rather than dropping the whole notification.
@Test func aClickURLWithAnUnsupportedSchemeBecomesNilButTheNotificationStillPresents() throws {
    let json = """
    {"id":"m1","time":1788353322,"event":"message","topic":"alerts","priority":3,\
    "click":"javascript:alert(1)","message":"B"}
    """
    let event = try JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
    guard case .present(let r) = NotificationDecision.decide(
        event: event, serverID: sid, settings: unmuted, preferences: .default)
    else { Issue.record("suppressed"); return }
    #expect(r.clickURL == nil)
}

/// `TRACE` (and any verb outside the fixed allow-list) is dropped rather
/// than forwarded to `URLSession` as-is.
@Test func anHTTPActionWithAnUnsupportedMethodIsDropped() {
    let actions = """
    [{"id":"a1","action":"http","label":"Do","url":"https://example.com","method":"TRACE"}]
    """
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, actions: actions), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    #expect(r.actions.isEmpty)
    #expect(r.categoryIdentifier == nil)
}

/// Auth-bearing and hop-by-hop headers must never reach the outgoing
/// request; an ordinary header the action set is left alone.
@Test func anHTTPActionStripsAuthAndHopByHopHeadersButKeepsOthers() {
    let actions = """
    [{"id":"a1","action":"http","label":"Do","url":"https://example.com","method":"POST",
      "headers":{"Authorization":"Bearer xyz","Cookie":"a=b","X-Forwarded-For":"1.2.3.4","X-Custom":"keep"}}]
    """
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, actions: actions), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    guard case .http(_, _, let headers, _) = r.actions.first?.kind else {
        Issue.record("expected an http action"); return
    }
    #expect(headers == ["X-Custom": "keep"])
}

/// A pasted newline can execute as a shell command; the button label is
/// attacker-chosen to make pasting look reasonable.
@Test func aCopyActionStripsControlCharacters() {
    let actions = """
    [{"id":"a1","action":"copy","label":"Copy","value":"line1\\nline2\\r\\n"}]
    """
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, actions: actions), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    guard case .copy(let value) = r.actions.first?.kind else {
        Issue.record("expected a copy action"); return
    }
    #expect(value == "line1line2")
}

/// A truncated copy value is still useful; an unbounded one is a way to dump
/// arbitrary data onto the clipboard.
@Test func aCopyActionValueIsCappedAtOneKiB() {
    let longValue = String(repeating: "a", count: 2000)
    let actions = "[{\"id\":\"a1\",\"action\":\"copy\",\"label\":\"Copy\",\"value\":\"\(longValue)\"}]"
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, actions: actions), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    guard case .copy(let value) = r.actions.first?.kind else {
        Issue.record("expected a copy action"); return
    }
    #expect(value.count == 1024)
}

/// `String.count` measures grapheme clusters, not bytes: one base character
/// plus thousands of combining marks is still a single grapheme, so a
/// `count`-based cap lets an unbounded byte payload straight onto the
/// clipboard. This value is one grapheme cluster (`count == 1`) but tens of
/// thousands of UTF-8 bytes, so a correct cap must still shrink it — and
/// verifying `value.count` (as the sibling test above does) would not catch
/// a regression back to a `count`-based cap, since `count` never moves here
/// either way. Confirmed against the pre-fix implementation: reverting
/// `truncatedToUTF8Bytes` to `String(stripped.prefix(maxCopyValueBytes))`
/// (a `count`-based prefix) leaves `value.utf8.count` at ~20001 and fails
/// this assertion; the byte-bounding implementation passes it.
@Test func aCopyActionValueIsCappedByUTF8BytesNotGraphemeClusters() {
    let combiningMark = "\u{0301}" // U+0301 COMBINING ACUTE ACCENT, 2 UTF-8 bytes
    let value = "e" + String(repeating: combiningMark, count: 10_000)
    #expect(value.count == 1) // one grapheme cluster: base + all its combining marks
    let actions = "[{\"id\":\"a1\",\"action\":\"copy\",\"label\":\"Copy\",\"value\":\"\(value)\"}]"
    guard case .present(let r) = NotificationDecision.decide(
        event: message(priority: 3, actions: actions), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    guard case .copy(let sanitized) = r.actions.first?.kind else {
        Issue.record("expected a copy action"); return
    }
    #expect(sanitized.utf8.count <= 1024)
    #expect(sanitized.utf8.count > 0)
}

/// `attachmentURL` went through no scheme check at all until this fix — the
/// one URL field the earlier sweep of `clickURL`/action URLs missed. It is
/// dead code today (nothing reads it yet), which is exactly why a missing
/// check here is easy to overlook: there is no visible symptom until a
/// downloader starts reading it.
@Test func anAttachmentURLWithAnUnsupportedSchemeBecomesNil() throws {
    let json = """
    {"id":"m1","time":1788353322,"event":"message","topic":"alerts","priority":3,\
    "attachment":{"name":"a.txt","url":"file:///etc/passwd"},"message":"B"}
    """
    let event = try JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
    guard case .present(let r) = NotificationDecision.decide(
        event: event, serverID: sid, settings: unmuted, preferences: .default)
    else { Issue.record("suppressed"); return }
    #expect(r.attachmentURL == nil)
}

@Test func anAttachmentURLWithASupportedSchemeIsKept() throws {
    let json = """
    {"id":"m1","time":1788353322,"event":"message","topic":"alerts","priority":3,\
    "attachment":{"name":"a.txt","url":"https://example.com/a.txt"},"message":"B"}
    """
    let event = try JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
    guard case .present(let r) = NotificationDecision.decide(
        event: event, serverID: sid, settings: unmuted, preferences: .default)
    else { Issue.record("suppressed"); return }
    #expect(r.attachmentURL == URL(string: "https://example.com/a.txt"))
}
