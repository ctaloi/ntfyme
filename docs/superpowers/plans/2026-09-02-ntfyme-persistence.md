# NtfyMe Persistence and Retention Implementation Plan (Stage 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the local store the source of truth — every message a connection receives is persisted, deduplicated, and pruned on a retention policy, with watermarks that survive a restart.

**Architecture:** A `@ModelActor` store owns the SwiftData container. Model objects never cross an actor boundary; the store's public API takes and returns `Sendable` value types only. Three pre-persistence corrections land first, because each changes a type the schema would otherwise be designed against.

**Tech Stack:** Swift 6.2, SwiftData, Swift Testing, Foundation. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-02-mac-ntfy-design.md` — this plan implements §4, §5.1, §5.2 and §8, and closes two items §10 requires that Stage 1–2 deferred. Read §4, §5.2 and §8 before starting.

**Previous plan:** `docs/superpowers/plans/2026-09-02-ntfyme-foundation.md` (Stages 1–2, merged). Its "Measured ntfy behavior" table still applies.

## Global Constraints

Copied from the spec and from Stage 1–2's merged state. Every task's requirements implicitly include these.

- **Product `NtfyMe`, bundle id `dev.aloi.NtfyMe`, MIT.** Platform floor macOS 26 (`.macOS(.v26)`, `LSMinimumSystemVersion` `26.0`).
- **Toolchain:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` before every `swift` command, or `Testing` fails to resolve. Never `sudo xcode-select`. `timeout`/`gtimeout` are NOT installed — bound test runs with your agent's own timeout mechanism.
- **The repository is public** (github.com/ctaloi/ntfyme). No credentials, tokens, personal server URLs, personal topic names, internal hostnames, or signing material in any committed file — fixtures included.
- **`NtfyKit` imports no UI framework.** No AppKit, no SwiftUI. SwiftData is fine; **SwiftUI's `@Query` is not** — the store is a library, and `@Query` views belong to Plan 3. A reviewer should reject any task that imports SwiftUI into `NtfyKit`.
- **Swift 6 strict concurrency.** `@Model` classes are not `Sendable`. **No `@Model` instance may cross an actor boundary.** The store's public API takes and returns value types (`NtfyEvent`, `TopicWatermark`, `MessageSnapshot`, `RetentionPolicy`, `PruneResult`) exclusively. This is the single rule that makes SwiftData workable here.
- **No silent failures.** Never `try?` away an error without a comment justifying *why it cannot fail* — not merely that it is unlikely. Stage 1–2 shipped two real bugs from this shape.
- **Message bodies are sensitive** — they carry hostnames and internal URLs. They must never reach a log or an error string. Logging goes through `NtfyKit/Log.swift`, whose doc comment states what each site may interpolate; if you add a site, update it.
- **Attachment *files* are out of scope.** The `Attachment` model and its `localFilename` field are in scope, and retention must delete files that exist. Actually downloading them is Plan 3/4. Do not grow a downloader.
- Test output must be pristine — warnings are findings.
- **A `Subscription` must always be linked to its `Server`.** `MessageStore` scopes every watermark lookup through `server.subscriptions`, because two servers may legitimately carry a topic of the same name and advancing the wrong one would make the other resume from a point it never reached. A fixture that inserts a bare `Subscription` will silently find no watermarks.

### The test rule this plan exists under

Stage 1–2 shipped **four separate tests that looked rigorous and pinned nothing**. All four were negative assertions never demonstrated able to fail. This plan is full of that shape — "the row was not duplicated", "the pruned message is gone", "the quiet topic did not trigger a gap".

**Any test whose only assertion is `== false`, `== nil`, `isEmpty`, or a count that did not change MUST be run once against a deliberately broken build before it is accepted.** Break the thing the test targets, watch the test fail, restore, watch it pass. Report both results. A negative assertion is evidence only when paired with a positive control — an event causally later than the forbidden one, proving the forbidden path had its chance.

## File Structure

```
Sources/NtfyKit/
  Networking/AuthCredential.swift          MODIFY  .none -> .unauthenticated
  Networking/StreamClient.swift            NEW     protocol seam + conformance
  Networking/WatermarkResolver.swift       MODIFY  caughtUpTo, per §5.2
  Networking/ServerConnection.swift        MODIFY  record caughtUpTo; diagnostics; snapshot
  Networking/ConnectionDiagnostic.swift    NEW     latched events the state enum cannot carry
  Networking/StreamingSession.swift        NEW     URLSession config for long-lived streams

  Persistence/Models.swift                 NEW     @Model Server, Subscription, Message, Attachment
  Persistence/MessageSnapshot.swift        NEW     Sendable DTO crossing the actor boundary
  Persistence/RetentionPolicy.swift        NEW     policy + PruneResult value types
  Persistence/MessageStore.swift           NEW     @ModelActor: insert, watermarks, prune
  Persistence/Ingest.swift                 NEW     connection events -> store
  Persistence/Backfill.swift               NEW     one-shot poll for a newly added topic

Tests/NtfyKitTests/
  Support/FakeStreamClient.swift           NEW     deterministic stream double
  Support/StoreFixtures.swift              NEW     in-memory container helpers
  StreamClientSeamTests.swift              NEW
  CaughtUpToTests.swift                    NEW
  SwiftDataBehaviorTests.swift             NEW     the measured-not-assumed probe
  MessageStoreTests.swift                  NEW
  RetentionTests.swift                     NEW
  IngestTests.swift                        NEW
  BackfillTests.swift                      NEW
  ConnectionDiagnosticTests.swift          NEW
```

---

### Task 1: Rename `AuthCredential.none` to `.unauthenticated`

Mechanical, and it must happen before persistence stores it. `Server.authKind` is exactly the record that would make this a breaking change.

**Files:**
- Modify: `Sources/NtfyKit/Networking/AuthCredential.swift`, `Sources/NtfyKit/Security/KeychainStore.swift`
- Modify: `Tests/NtfyKitTests/AuthCredentialTests.swift`, `Tests/NtfyKitTests/KeychainStoreTests.swift`, and any other call site the compiler names

**Interfaces:**
- Consumes: nothing.
- Produces: `AuthCredential.unauthenticated` replacing `.none`. Cases are now `.unauthenticated`, `.bearer(token:)`, `.basic(user:password:)`.

- [ ] **Step 1: Rename the case and let the compiler find the call sites**

In `AuthCredential.swift`, rename `case none` to `case unauthenticated`, and add a doc comment saying why:

```swift
public enum AuthCredential: Sendable, Equatable {
    /// No credential. Named `unauthenticated` rather than `none` because this
    /// type is held as `AuthCredential?` downstream, where `.none` would be
    /// ambiguous with `Optional.none` at every call site.
    case unauthenticated
    case bearer(token: String)
    case basic(user: String, password: String)
```

- [ ] **Step 2: Build and fix every error the compiler reports**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | grep -E "error:" | head -20
```

Fix each. `KeychainStore` is the main consumer: `save(.none, …)` becomes `save(.unauthenticated, …)`, and its `encode`/`load` paths that return or compare `.none` change with it. **Read each site rather than blind-replacing** — some `.none` occurrences are genuinely `Optional.none` and must not change.

- [ ] **Step 3: Run the full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: 76/76 passing, zero warnings. This is a rename; no behavior changes.

- [ ] **Step 4: Confirm no stale name survives**

```bash
grep -rn "AuthCredential.none\|\.none," Sources/ Tests/ | grep -i credential || echo "clean"
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename AuthCredential.none to .unauthenticated"
```

---

### Task 2: `StreamClient` protocol seam and a deterministic test double

Every `ServerConnection` test today needs a real socket and `waitUntil` polling. The persistence tests that follow want to assert "message arrives → row exists → watermark advances" without that. This seam is the cheapest task in the plan and it pays back across every later one.

**Files:**
- Create: `Sources/NtfyKit/Networking/StreamClient.swift`
- Modify: `Sources/NtfyKit/Networking/ServerConnection.swift` (the `client` property and `init`)
- Create: `Tests/NtfyKitTests/Support/FakeStreamClient.swift`, `Tests/NtfyKitTests/StreamClientSeamTests.swift`

**Interfaces:**
- Consumes: `NtfyStreamClient.StreamElement`, `NtfyStreamClient.Error`.
- Produces:
  - `protocol StreamClient: Sendable { func stream(_ request: URLRequest) -> AsyncThrowingStream<NtfyStreamClient.StreamElement, Error> }`
  - `NtfyStreamClient: StreamClient` (conformance only; no behavior change).
  - `ServerConnection.init(..., client: any StreamClient = NtfyStreamClient(), ...)`.
  - `FakeStreamClient` (test target) with `enqueue(_ elements: [NtfyStreamClient.StreamElement])`, `enqueueError(_:)`, `var requestCount: Int`, `var lastRequest: URLRequest?`.

- [ ] **Step 1: Write the failing seam test**

`Tests/NtfyKitTests/StreamClientSeamTests.swift`:

```swift
import Foundation
import Testing
@testable import NtfyKit

@Test func connectionDrivesEventsFromAnInjectedClient() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.minimalMessage)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake,
        sleeper: ManualSleeper()
    )

    let received = Collector()
    let consumer = Task { for await event in connection.events { await received.add(event) } }
    defer { consumer.cancel() }

    await connection.start()
    #expect(await waitUntil { await received.count == 1 })
    #expect(await received.first?.message == "A1")
    await connection.stop()
}

/// No socket, no polling for a port: the whole exchange is in-process.
@Test func theFakeClientRecordsTheRequestItWasGiven() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake,
        sleeper: ManualSleeper()
    )
    await connection.start()
    #expect(await waitUntil { await fake.requestCount == 1 })
    #expect(await fake.lastRequest?.url?.absoluteString.hasPrefix("https://ntfy.example.com/alerts/json") == true)
    await connection.stop()
}
```

These tests use three helpers that do not exist yet. Create them now in
`Tests/NtfyKitTests/Support/TestHelpers.swift` — **every later task in this plan
uses them**, so get them right here:

```swift
import Foundation
import Testing
@testable import NtfyKit

extension Fixtures {
    /// Decode a fixture string into an `NtfyEvent`.
    static func decode(_ json: String) throws -> NtfyEvent {
        try JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
    }
}

/// Poll until `condition` holds or the deadline passes. Returns whether it
/// held. Bounded by construction: a test that would otherwise hang fails
/// instead, which on this project is a hard requirement.
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Collects events from an `AsyncStream` without the test owning a mutable
/// local, which Swift 6 forbids capturing in a `Task`.
actor Collector {
    private var items: [NtfyEvent] = []
    var count: Int { items.count }
    var first: NtfyEvent? { items.first }
    func add(_ event: NtfyEvent) { items.append(event) }
}
```

`ServerConnectionTests.swift` already has a private `waitUntil`; delete that one
and let it use this shared version, so there is a single definition. Replace
`received.first?.messageBody` in the test above with `received.first?.message` —
`NtfyEvent`'s body field is `message`.

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter StreamClientSeamTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'FakeStreamClient' in scope`, and `ServerConnection.init` has no `client:` parameter of protocol type.

- [ ] **Step 3: Define the protocol**

`Sources/NtfyKit/Networking/StreamClient.swift`:

```swift
import Foundation

/// The seam between `ServerConnection` and the network.
///
/// `ServerConnection` took a concrete `NtfyStreamClient`, which meant every
/// state-machine test needed a real socket and timing-based polling. This
/// protocol lets the persistence and coordinator layers assert transitions
/// deterministically, in process.
public protocol StreamClient: Sendable {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<NtfyStreamClient.StreamElement, Swift.Error>
}

extension NtfyStreamClient: StreamClient {}
```

- [ ] **Step 4: Widen `ServerConnection` to accept it**

In `ServerConnection.swift`, change the stored property from `private let client: NtfyStreamClient` to `private let client: any StreamClient`, and the `init` parameter from `client: NtfyStreamClient = NtfyStreamClient()` to `client: any StreamClient = NtfyStreamClient()`. Nothing else changes — the call site is already `client.stream(request)`.

- [ ] **Step 5: Write the fake**

`Tests/NtfyKitTests/Support/FakeStreamClient.swift`:

```swift
import Foundation
@testable import NtfyKit

/// Deterministic `StreamClient`. Each `stream(_:)` call consumes one queued
/// script; an exhausted queue yields an empty, immediately-finished stream,
/// which `ServerConnection` treats as a clean disconnect.
actor FakeStreamClient: StreamClient {
    private enum Script {
        case elements([NtfyStreamClient.StreamElement])
        case failure(Swift.Error)
    }

    private var scripts: [Script] = []
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    func enqueue(_ elements: [NtfyStreamClient.StreamElement]) {
        scripts.append(.elements(elements))
    }

    func enqueueError(_ error: Swift.Error) {
        scripts.append(.failure(error))
    }

    private func take(_ request: URLRequest) -> Script {
        requestCount += 1
        lastRequest = request
        return scripts.isEmpty ? .elements([]) : scripts.removeFirst()
    }

    nonisolated func stream(
        _ request: URLRequest
    ) -> AsyncThrowingStream<NtfyStreamClient.StreamElement, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch await self.take(request) {
                case .elements(let elements):
                    for element in elements { continuation.yield(element) }
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 6: Run to verify it passes**

```bash
swift test --filter StreamClientSeamTests 2>&1 | tail -20
swift test 2>&1 | tail -3
```

Expected: 2 new tests pass; all 76 prior tests still pass. The existing socket-based tests keep working because `NtfyStreamClient` still conforms.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: put a StreamClient protocol between the connection and the network"
```

---

### Task 3: The resume point becomes "caught up to", per spec §5.2

Read spec §5.2 first — it records this decision and the reasoning.

Resuming from `min(lastMessageTime)` is wrong for a quiet topic: one that merely received nothing for longer than the server's cache window drags `since` outside that window on every reconnect, producing a full-cache replay of every topic and a `hasHistoryGap` that is **false** — nothing was missed.

Every `open` and `keepalive` line carries a server `time`, and receiving one means everything up to that time has been delivered on all subscribed topics. The connection currently discards it.

**Files:**
- Modify: `Sources/NtfyKit/Networking/WatermarkResolver.swift`
- Modify: `Sources/NtfyKit/Networking/ServerConnection.swift`
- Create: `Tests/NtfyKitTests/CaughtUpToTests.swift`
- Modify: `Tests/NtfyKitTests/WatermarkResolverTests.swift` (existing tests gain the new parameter)

**Interfaces:**
- Consumes: `TopicWatermark`, `SinceParameter`, `WatermarkResolver.Resolution`.
- Produces:
  - `WatermarkResolver.resolve(watermarks:caughtUpTo:cacheWindow:now:margin:) -> Resolution` — `caughtUpTo: Date?` is a new **second** parameter.
  - `ServerConnection.caughtUpTo: Date?` (actor-isolated, readable) advanced on every line carrying a server `time`.

- [ ] **Step 1: Write the failing tests**

`Tests/NtfyKitTests/CaughtUpToTests.swift`:

```swift
import Foundation
import Testing
@testable import NtfyKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let window: TimeInterval = 12 * 3600

private func wm(_ topic: String, _ offset: TimeInterval?) -> TopicWatermark {
    TopicWatermark(topic: topic, lastMessageTime: offset.map { now.addingTimeInterval($0) })
}

/// The whole point of §5.2: a topic quiet for longer than the cache window
/// must not drag the resume point out of the window when the connection was
/// demonstrably caught up more recently.
@Test func aQuietTopicDoesNotDragTheResumePointOutOfTheWindow() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("quiet", -(window + 7200)), wm("busy", -60)],
        caughtUpTo: now.addingTimeInterval(-120),
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 120 - 5))
    #expect(r.hasHistoryGap == false)
}

/// A genuinely long disconnect still reports a gap: caughtUpTo is old too.
@Test func aRealLongDisconnectStillReportsAGap() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -(window + 7200))],
        caughtUpTo: now.addingTimeInterval(-(window + 3600)),
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.hasHistoryGap == true)
}

/// caughtUpTo never moves the resume point FORWARD past an unread message.
/// If a topic's watermark is newer, the max() picks caughtUpTo only when it
/// is later than the oldest watermark — never later than the newest.
@Test func caughtUpToNeverSkipsPastAnOlderWatermarkThatIsStillInWindow() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -600), wm("b", -300)],
        caughtUpTo: now.addingTimeInterval(-900),
        cacheWindow: window, now: now, margin: 5
    )
    // caughtUpTo (-900) is older than min watermark (-600), so min wins.
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 600 - 5))
}

@Test func nilCaughtUpToBehavesExactlyAsBefore() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -600), wm("b", -120)],
        caughtUpTo: nil,
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 600 - 5))
}

@Test func caughtUpToAloneResolvesWhenNoTopicHasAWatermark() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", nil)],
        caughtUpTo: now.addingTimeInterval(-90),
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 90 - 5))
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter CaughtUpToTests 2>&1 | tail -20
```

Expected: build error — `resolve` has no `caughtUpTo:` parameter.

- [ ] **Step 3: Change the resolver**

In `WatermarkResolver.swift`, replace the body of `resolve` with:

```swift
    public static func resolve(
        watermarks: [TopicWatermark],
        caughtUpTo: Date? = nil,
        cacheWindow: TimeInterval,
        now: Date = Date(),
        margin: TimeInterval = 5
    ) -> Resolution {
        // §5.2: the resume point is "everything up to here has been delivered",
        // not "the oldest message we happen to hold". A topic that was merely
        // quiet must not drag the resume point out of the server's cache
        // window — receiving any line (open or keepalive) proves delivery up
        // to that line's server timestamp across every subscribed topic.
        let oldestMessage = watermarks.compactMap(\.lastMessageTime).min()

        let resumeFrom: Date?
        switch (oldestMessage, caughtUpTo) {
        case (nil, nil):        resumeFrom = nil
        case (let m?, nil):     resumeFrom = m
        case (nil, let c?):     resumeFrom = c
        case (let m?, let c?):  resumeFrom = max(m, c)
        }

        guard let resumeFrom else {
            return Resolution(since: .all, hasHistoryGap: false)
        }

        let sinceDate = resumeFrom.addingTimeInterval(-margin)
        let gap = now.timeIntervalSince(sinceDate) > cacheWindow
        return Resolution(
            since: .unixTime(Int(sinceDate.timeIntervalSince1970.rounded(.down))),
            hasHistoryGap: gap
        )
    }
```

- [ ] **Step 4: Make `ServerConnection` record it**

Add a stored property and advance it wherever a line arrives. In `ServerConnection.swift`, add:

```swift
    /// Server timestamp of the most recent line of any kind. Receiving a line
    /// proves the server has delivered everything up to that point on every
    /// subscribed topic, which is what makes §5.2's resume rule correct.
    public private(set) var caughtUpTo: Date?
```

In the stream loop, immediately after the existing cancellation guard that follows `await watchdog.pet()`, and **before** the `guard case .event` filter is applied to non-message kinds, advance it for every event that carries a time:

```swift
            if case .event(let element) = element, element.time > 0 {
                let lineTime = element.date
                if caughtUpTo == nil || lineTime > caughtUpTo! { caughtUpTo = lineTime }
            }
```

Then pass it into the resolver in `connectOnce`:

```swift
        let resolution = WatermarkResolver.resolve(
            watermarks: watermarks,
            caughtUpTo: caughtUpTo,
            cacheWindow: cacheWindow
        )
```

Add the `caughtUpTo:` argument to the existing `WatermarkResolverTests.swift` calls (pass `nil`) so they keep compiling and keep asserting the pre-§5.2 behavior.

- [ ] **Step 5: Add a connection-level test using the Task 2 seam**

Append to `CaughtUpToTests.swift`:

```swift
/// A keepalive carries no message but does advance the resume point.
@Test func aKeepaliveAdvancesCaughtUpTo() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.keepaliveEvent)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake,
        sleeper: ManualSleeper()
    )
    await connection.start()
    #expect(await waitUntil { await connection.caughtUpTo != nil })
    // keepaliveEvent's time is 1788352857.
    #expect(await connection.caughtUpTo == Date(timeIntervalSince1970: 1_788_352_857))
    await connection.stop()
}
```

- [ ] **Step 6: Run and verify, including the negative assertions**

```bash
swift test --filter "CaughtUpToTests|WatermarkResolverTests" 2>&1 | tail -20
swift test 2>&1 | tail -3
```

`aQuietTopicDoesNotDragTheResumePointOutOfTheWindow` and `nilCaughtUpToBehavesExactlyAsBefore` both assert `hasHistoryGap == false` or an unchanged value. **Per the test rule, mutate and verify:** temporarily replace the `max(m, c)` with `m` (ignoring `caughtUpTo`), confirm `aQuietTopicDoesNotDragTheResumePointOutOfTheWindow` FAILS, restore, confirm it passes. Report both.

- [ ] **Step 7: Update the spec**

In §5.2, change "**Decided 2026-09-02, to be implemented with the persisted watermark model in the persistence plan.** The Stage 1–2 code implements the simpler rule below and is knowingly incomplete on this point." to record that it is now implemented, naming the commit.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: resume from 'caught up to', not the oldest message watermark"
```

---

### Task 4: Measure SwiftData's actual duplicate-key behavior

Spec §4 hedges between two mechanisms: `uniqueKey` is `@Attribute(.unique)`, *and* the store "queries existing keys for a batch before inserting rather than relying solely on unique-constraint upsert semantics." Those are different. Deduplication is what makes replay-on-reconnect safe, so this is the one invariant in this plan that cannot be wrong.

Establish empirically which behavior you get, before the ingest path is built on it. This is the same discipline that produced Plan 1's `since=` table.

**Files:**
- Create: `Tests/NtfyKitTests/SwiftDataBehaviorTests.swift`, `Tests/NtfyKitTests/Support/StoreFixtures.swift`
- Create: `Sources/NtfyKit/Persistence/Models.swift` (minimal — only what the probe needs; Task 5 completes it)

**Interfaces:**
- Consumes: nothing.
- Produces: `StoreFixtures.inMemoryContainer() throws -> ModelContainer`; a documented, tested statement of duplicate-key behavior that Task 6 relies on.

- [ ] **Step 1: Write the probe as real tests**

`Tests/NtfyKitTests/Support/StoreFixtures.swift`:

```swift
import Foundation
import SwiftData
@testable import NtfyKit

enum StoreFixtures {
    /// In-memory container. Each call gets its own store, so tests never share
    /// state and never touch the user's real database.
    static func inMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Message.self, Subscription.self,
                                  Server.self, Attachment.self,
                                  configurations: config)
    }
}
```

`Tests/NtfyKitTests/SwiftDataBehaviorTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import NtfyKit

/// These tests document MEASURED SwiftData behavior that Task 6's dedupe
/// depends on. If a toolchain upgrade changes the answer, these fail first
/// and loudly, rather than the ingest path silently duplicating rows.
@Test func insertingTwoRowsWithTheSameUniqueKeyDoesNotProduceTwoRows() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)

    let key = "srv/alerts/abc123"
    context.insert(Message(uniqueKey: key, messageID: "abc123", topic: "alerts",
                           serverID: UUID(), time: Date(timeIntervalSince1970: 1),
                           body: "first"))
    try context.save()

    context.insert(Message(uniqueKey: key, messageID: "abc123", topic: "alerts",
                           serverID: UUID(), time: Date(timeIntervalSince1970: 2),
                           body: "second"))
    try context.save()

    let all = try context.fetch(FetchDescriptor<Message>())
    #expect(all.count == 1)
}

/// Records WHICH of the two survives — upsert-last-wins vs keep-first. Task 6
/// must not assume; whichever this reports is what the dedupe is designed for.
@Test func recordsWhichRowSurvivesADuplicateKeyInsert() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let key = "srv/alerts/dup"

    context.insert(Message(uniqueKey: key, messageID: "dup", topic: "alerts",
                           serverID: UUID(), time: Date(timeIntervalSince1970: 1),
                           body: "first"))
    try context.save()
    context.insert(Message(uniqueKey: key, messageID: "dup", topic: "alerts",
                           serverID: UUID(), time: Date(timeIntervalSince1970: 2),
                           body: "second"))
    try context.save()

    let all = try context.fetch(FetchDescriptor<Message>())
    #expect(all.count == 1)
    // Whichever this is, write it into the doc comment on MessageStore.insert.
    #expect(all.first?.body == "second")
}

@Test func differentKeysCoexist() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let serverID = UUID()

    context.insert(Message(uniqueKey: "srv/alerts/a", messageID: "a", topic: "alerts",
                           serverID: serverID, time: Date(timeIntervalSince1970: 1), body: "a"))
    context.insert(Message(uniqueKey: "srv/alerts/b", messageID: "b", topic: "alerts",
                           serverID: serverID, time: Date(timeIntervalSince1970: 2), body: "b"))
    try context.save()

    #expect(try context.fetch(FetchDescriptor<Message>()).count == 2)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter SwiftDataBehaviorTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'Message' in scope`.

- [ ] **Step 3: Write just enough of the models to run the probe**

`Sources/NtfyKit/Persistence/Models.swift` — the full schema is Task 5; write `Message` now with the fields the probe uses, plus empty `Server`, `Subscription`, `Attachment` shells so the container can be created:

```swift
import Foundation
import SwiftData

@Model
public final class Message {
    @Attribute(.unique) public var uniqueKey: String
    public var messageID: String
    public var topic: String
    public var serverID: UUID
    public var time: Date
    public var body: String

    public init(uniqueKey: String, messageID: String, topic: String,
                serverID: UUID, time: Date, body: String) {
        self.uniqueKey = uniqueKey
        self.messageID = messageID
        self.topic = topic
        self.serverID = serverID
        self.time = time
        self.body = body
    }
}

@Model public final class Server { public var id: UUID; public init(id: UUID) { self.id = id } }
@Model public final class Subscription { public var topic: String; public init(topic: String) { self.topic = topic } }
@Model public final class Attachment { public var name: String; public init(name: String) { self.name = name } }
```

- [ ] **Step 4: Run and RECORD what actually happened**

```bash
swift test --filter SwiftDataBehaviorTests 2>&1 | tail -30
```

**If a test fails, that is the finding — do not change the test to match.** Adjust the *assertion* to what SwiftData actually does, and say so prominently in your report. In particular:

- If two rows survive, `@Attribute(.unique)` is not upserting on this toolchain, and Task 6's query-before-insert becomes **load-bearing rather than belt-and-braces**. Report that in capitals.
- If `save()` throws instead, record the error and adjust the test to expect a throw.
- If the surviving row is the first rather than the second, record that.

- [ ] **Step 5: Write the measured behavior into the plan and spec**

Add a short "Measured SwiftData behavior" table to this plan file, directly under Global Constraints, in the same style as Plan 1's ntfy table: what you inserted, what happened, and what Task 6 must therefore do. Update spec §4's hedged sentence to state the measured answer.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "test: measure SwiftData duplicate-key behavior before relying on it"
```

---

### Task 5: The full SwiftData schema

**Files:**
- Modify: `Sources/NtfyKit/Persistence/Models.swift` (replace the Task 4 shells)
- Create: `Sources/NtfyKit/Persistence/MessageSnapshot.swift`
- Modify: `Tests/NtfyKitTests/SwiftDataBehaviorTests.swift` if constructor signatures move

**Interfaces:**
- Consumes: `AuthCredential` (for `authKind`), `NtfyAction`, `NtfyPriority`.
- Produces:
  - `@Model Server` — `id: UUID`, `name`, `baseURLString`, `authKindRaw`, `sortOrder`, `caughtUpTo: Date?`, `cacheWindowSeconds: Double`, `subscriptions: [Subscription]`.
  - `@Model Subscription` — `id`, `topic`, `displayName`, `server`, `lastMessageID`, `lastMessageTime`, `muted`, `minAlertPriority`, `symbolName`, `accentColorHex`.
  - `@Model Message` — the full §4 field list plus `uniqueKey`.
  - `@Model Attachment` — `name`, `urlString`, `type`, `size`, `expires`, `localFilename`.
  - `struct MessageSnapshot: Sendable, Equatable, Identifiable` — the value type that crosses the actor boundary.
  - `Message.uniqueKey(serverID:topic:messageID:) -> String` static helper.

- [ ] **Step 1: Write the failing tests**

Append to `SwiftDataBehaviorTests.swift`:

```swift
@Test func uniqueKeyIsComposedOfServerTopicAndMessageID() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    #expect(Message.uniqueKey(serverID: id, topic: "alerts", messageID: "abc") ==
            "11111111-2222-3333-4444-555555555555/alerts/abc")
}

@Test func deletingAServerCascadesToItsSubscriptions() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)

    let server = Server(name: "Example", baseURLString: "https://ntfy.example.com")
    let sub = Subscription(topic: "alerts", server: server)
    context.insert(server)
    context.insert(sub)
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Subscription>()).count == 1)

    context.delete(server)
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Subscription>()).isEmpty)
}

@Test func aSnapshotCarriesEverythingTheUiNeedsWithoutTheModelObject() throws {
    let serverID = UUID()
    let message = Message(
        serverID: serverID, topic: "alerts", messageID: "abc",
        time: Date(timeIntervalSince1970: 1_788_353_322),
        title: "Service recovered", body: "**db-01** back to healthy",
        priority: 3, tags: ["white_check_mark"],
        click: "https://example.com/status", iconURL: nil,
        contentType: "text/markdown", actionsJSON: nil
    )
    let snapshot = message.snapshot
    #expect(snapshot.title == "Service recovered")
    #expect(snapshot.isMarkdown == true)
    #expect(snapshot.resolvedPriority == .default)
    #expect(snapshot.tags == ["white_check_mark"])
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter SwiftDataBehaviorTests 2>&1 | tail -20
```

Expected: build errors on the new initializers and `snapshot`.

- [ ] **Step 3: Write the models**

Replace `Sources/NtfyKit/Persistence/Models.swift`:

```swift
import Foundation
import SwiftData

/// One configured ntfy server.
///
/// Credentials are NOT here. They live in the Keychain keyed by `id` (spec §9),
/// so this record can be exported or inspected without leaking one.
@Model
public final class Server {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var baseURLString: String
    /// `AuthCredential`'s case name; the value itself is in the Keychain.
    public var authKindRaw: String
    public var sortOrder: Int
    /// §5.2: everything up to here has been delivered on every topic of this
    /// server. Persisted so a restart resumes correctly rather than replaying.
    public var caughtUpTo: Date?
    /// Server-side cache window. ntfy.sh is 12h; self-hosted servers vary, so
    /// it belongs on the server rather than as a client-wide constant.
    public var cacheWindowSeconds: Double

    @Relationship(deleteRule: .cascade, inverse: \Subscription.server)
    public var subscriptions: [Subscription]

    public init(id: UUID = UUID(), name: String, baseURLString: String,
                authKindRaw: String = "unauthenticated", sortOrder: Int = 0,
                caughtUpTo: Date? = nil, cacheWindowSeconds: Double = 12 * 3600) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.authKindRaw = authKindRaw
        self.sortOrder = sortOrder
        self.caughtUpTo = caughtUpTo
        self.cacheWindowSeconds = cacheWindowSeconds
        self.subscriptions = []
    }

    public var baseURL: URL? { URL(string: baseURLString) }
}

/// One topic on one server.
@Model
public final class Subscription {
    @Attribute(.unique) public var id: UUID
    public var topic: String
    public var displayName: String?
    public var server: Server?
    /// Diagnostics and log correlation only — `since` is built from time
    /// (spec §5.1), because an unresolvable id returns a silent full replay.
    public var lastMessageID: String?
    public var lastMessageTime: Date?
    public var muted: Bool
    /// Record without alerting below this priority (1...5).
    public var minAlertPriority: Int
    public var symbolName: String?
    public var accentColorHex: String?

    public init(id: UUID = UUID(), topic: String, displayName: String? = nil,
                server: Server? = nil, lastMessageID: String? = nil,
                lastMessageTime: Date? = nil, muted: Bool = false,
                minAlertPriority: Int = 1, symbolName: String? = nil,
                accentColorHex: String? = nil) {
        self.id = id
        self.topic = topic
        self.displayName = displayName
        self.server = server
        self.lastMessageID = lastMessageID
        self.lastMessageTime = lastMessageTime
        self.muted = muted
        self.minAlertPriority = minAlertPriority
        self.symbolName = symbolName
        self.accentColorHex = accentColorHex
    }

    public var watermark: TopicWatermark {
        TopicWatermark(topic: topic, lastMessageTime: lastMessageTime)
    }
}

/// One received message. `uniqueKey` is what makes replay-on-reconnect safe.
@Model
public final class Message {
    @Attribute(.unique) public var uniqueKey: String
    public var messageID: String
    public var topic: String
    public var serverID: UUID
    public var time: Date
    public var expires: Date?
    public var title: String?
    public var body: String
    public var priority: Int
    public var tags: [String]
    public var click: String?
    public var iconURL: String?
    public var contentType: String?
    /// `[NtfyAction]` as JSON. Kept opaque so an action kind ntfy adds later
    /// round-trips rather than being dropped.
    public var actionsJSON: Data?
    @Relationship(deleteRule: .cascade) public var attachment: Attachment?
    public var isRead: Bool

    public static func uniqueKey(serverID: UUID, topic: String, messageID: String) -> String {
        "\(serverID.uuidString)/\(topic)/\(messageID)"
    }

    public init(serverID: UUID, topic: String, messageID: String, time: Date,
                expires: Date? = nil, title: String? = nil, body: String,
                priority: Int = 3, tags: [String] = [], click: String? = nil,
                iconURL: String? = nil, contentType: String? = nil,
                actionsJSON: Data? = nil, attachment: Attachment? = nil,
                isRead: Bool = false) {
        self.uniqueKey = Message.uniqueKey(serverID: serverID, topic: topic, messageID: messageID)
        self.serverID = serverID
        self.topic = topic
        self.messageID = messageID
        self.time = time
        self.expires = expires
        self.title = title
        self.body = body
        self.priority = priority
        self.tags = tags
        self.click = click
        self.iconURL = iconURL
        self.contentType = contentType
        self.actionsJSON = actionsJSON
        self.attachment = attachment
        self.isRead = isRead
    }
}

/// Attachment metadata. The FILE lives outside the database under
/// Application Support, so pruning reclaims real disk. Downloading is not
/// implemented in this plan.
@Model
public final class Attachment {
    public var name: String
    public var urlString: String
    public var type: String?
    public var size: Int?
    public var expires: Date?
    public var localFilename: String?

    public init(name: String, urlString: String, type: String? = nil,
                size: Int? = nil, expires: Date? = nil, localFilename: String? = nil) {
        self.name = name
        self.urlString = urlString
        self.type = type
        self.size = size
        self.expires = expires
        self.localFilename = localFilename
    }
}
```

Keep the Task 4 probe's `Message` initializer working, or update those three tests to the real initializer — your choice, but say which in your report.

- [ ] **Step 4: Write the snapshot type**

`Sources/NtfyKit/Persistence/MessageSnapshot.swift`:

```swift
import Foundation

/// A `Sendable` view of one `Message`.
///
/// `@Model` classes are not `Sendable` and must never cross an actor boundary
/// under Swift 6 strict concurrency. Every value the store hands out is one of
/// these instead.
public struct MessageSnapshot: Sendable, Equatable, Identifiable {
    public let id: String            // the uniqueKey
    public let messageID: String
    public let topic: String
    public let serverID: UUID
    public let time: Date
    public let title: String?
    public let body: String
    public let priority: Int
    public let tags: [String]
    public let click: String?
    public let iconURL: String?
    public let contentType: String?
    public let actionsJSON: Data?
    public let isRead: Bool

    public var isMarkdown: Bool { contentType == "text/markdown" }
    public var resolvedPriority: NtfyPriority { NtfyPriority(rawValue: priority) ?? .default }
    public var actions: [NtfyAction] {
        guard let actionsJSON else { return [] }
        // A stored blob this app wrote itself; a decode failure means the row
        // is corrupt, and an empty action list degrades the UI rather than
        // losing the message. Logged by the caller, not swallowed silently.
        return (try? JSONDecoder().decode([NtfyAction].self, from: actionsJSON)) ?? []
    }
}

extension Message {
    public var snapshot: MessageSnapshot {
        MessageSnapshot(id: uniqueKey, messageID: messageID, topic: topic,
                        serverID: serverID, time: time, title: title, body: body,
                        priority: priority, tags: tags, click: click,
                        iconURL: iconURL, contentType: contentType,
                        actionsJSON: actionsJSON, isRead: isRead)
    }
}
```

- [ ] **Step 5: Run and verify**

```bash
swift test --filter SwiftDataBehaviorTests 2>&1 | tail -20
swift test 2>&1 | tail -3
```

`deletingAServerCascadesToItsSubscriptions` asserts `isEmpty` — a negative. **Mutate and verify:** change the relationship's `deleteRule` to `.nullify`, confirm the test FAILS, restore, confirm it passes. Report both.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: SwiftData schema for servers, subscriptions, messages, attachments"
```

---

### Task 6: `MessageStore` — insert with dedupe, read and write watermarks

**Files:**
- Create: `Sources/NtfyKit/Persistence/MessageStore.swift`
- Create: `Tests/NtfyKitTests/MessageStoreTests.swift`

**Interfaces:**
- Consumes: all Task 5 models, `NtfyEvent`, `TopicWatermark`, `MessageSnapshot`.
- Produces: `@ModelActor public actor MessageStore` with
  - `func insert(_ events: [NtfyEvent], serverID: UUID) throws -> InsertResult`
  - `func watermarks(forServer serverID: UUID) throws -> [TopicWatermark]`
  - `func caughtUpTo(forServer serverID: UUID) throws -> Date?`
  - `func setCaughtUpTo(_ date: Date, forServer serverID: UUID) throws`
  - `func messages(forServer serverID: UUID, topic: String?, limit: Int) throws -> [MessageSnapshot]`
  - `func messageCount() throws -> Int`
  - `struct InsertResult: Sendable, Equatable { public let inserted: Int; public let duplicatesSkipped: Int }`

- [ ] **Step 1: Write the failing tests**

`Tests/NtfyKitTests/MessageStoreTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import NtfyKit

private func event(_ id: String, topic: String = "alerts", time: Int, body: String) -> NtfyEvent {
    let json = """
    {"id":"\(id)","time":\(time),"event":"message","topic":"\(topic)","message":"\(body)"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private func makeStore() throws -> (MessageStore, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example",
                        baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()
    return (MessageStore(modelContainer: container), serverID)
}

@Test func insertingMessagesPersistsThem() async throws {
    let (store, serverID) = try makeStore()
    let result = try await store.insert(
        [event("a", time: 100, body: "one"), event("b", time: 200, body: "two")],
        serverID: serverID)
    #expect(result.inserted == 2)
    #expect(result.duplicatesSkipped == 0)
    #expect(try await store.messageCount() == 2)
}

/// The invariant the whole reconnect design rests on: an overlapping replay
/// window must upsert, not duplicate.
@Test func replayingAnOverlappingWindowDoesNotDuplicateRows() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "one"),
                                event("b", time: 200, body: "two")], serverID: serverID)
    let second = try await store.insert([event("b", time: 200, body: "two"),
                                         event("c", time: 300, body: "three")], serverID: serverID)
    #expect(second.inserted == 1)
    #expect(second.duplicatesSkipped == 1)
    #expect(try await store.messageCount() == 3)
}

/// Same message id on two different topics is two different messages.
@Test func theSameMessageIdOnDifferentTopicsIsNotADuplicate() async throws {
    let (store, serverID) = try makeStore()
    let result = try await store.insert(
        [event("same", topic: "alerts", time: 100, body: "a"),
         event("same", topic: "deploys", time: 100, body: "b")], serverID: serverID)
    #expect(result.inserted == 2)
    #expect(try await store.messageCount() == 2)
}

@Test func insertingAdvancesTheTopicWatermark() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "one"),
                                event("b", time: 300, body: "two"),
                                event("c", time: 200, body: "three")], serverID: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.count == 1)
    #expect(marks.first?.topic == "alerts")
    // Newest wins regardless of arrival order.
    #expect(marks.first?.lastMessageTime == Date(timeIntervalSince1970: 300))
}

/// An out-of-order late arrival must not move the watermark backwards.
@Test func anOlderMessageDoesNotRewindTheWatermark() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("b", time: 300, body: "new")], serverID: serverID)
    _ = try await store.insert([event("a", time: 100, body: "old")], serverID: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.first?.lastMessageTime == Date(timeIntervalSince1970: 300))
}

@Test func caughtUpToRoundTrips() async throws {
    let (store, serverID) = try makeStore()
    #expect(try await store.caughtUpTo(forServer: serverID) == nil)
    let t = Date(timeIntervalSince1970: 1_788_353_322)
    try await store.setCaughtUpTo(t, forServer: serverID)
    #expect(try await store.caughtUpTo(forServer: serverID) == t)
}

@Test func messagesComeBackNewestFirst() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "old"),
                                event("c", time: 300, body: "new"),
                                event("b", time: 200, body: "mid")], serverID: serverID)
    let page = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(page.map(\.body) == ["new", "mid", "old"])
}

/// Non-message events carry no content and must not become rows.
@Test func keepaliveAndOpenEventsAreNotStored() async throws {
    let (store, serverID) = try makeStore()
    let open = try Fixtures.decode(Fixtures.openEvent)
    let keepalive = try Fixtures.decode(Fixtures.keepaliveEvent)
    let result = try await store.insert([open, keepalive], serverID: serverID)
    #expect(result.inserted == 0)
    #expect(try await store.messageCount() == 0)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MessageStoreTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'MessageStore' in scope`.

- [ ] **Step 3: Write the store**

`Sources/NtfyKit/Persistence/MessageStore.swift`:

```swift
import Foundation
import SwiftData

/// Owns the SwiftData container. Every public method takes and returns
/// `Sendable` value types — no `@Model` instance ever leaves this actor,
/// because `@Model` classes are not `Sendable`.
@ModelActor
public actor MessageStore {
    public struct InsertResult: Sendable, Equatable {
        public let inserted: Int
        public let duplicatesSkipped: Int
    }

    /// Persists the message events in `events`, skipping any whose
    /// `uniqueKey` is already stored, and advances each topic's watermark to
    /// the newest message time seen.
    ///
    /// Duplicates are filtered by an explicit query rather than by relying on
    /// the unique constraint alone — see this plan's "Measured SwiftData
    /// behavior" table for why.
    @discardableResult
    public func insert(_ events: [NtfyEvent], serverID: UUID) throws -> InsertResult {
        let messages = events.filter { $0.kind == .message }
        guard !messages.isEmpty else { return InsertResult(inserted: 0, duplicatesSkipped: 0) }

        let keys = Set(messages.map {
            Message.uniqueKey(serverID: serverID, topic: $0.topic, messageID: $0.id)
        })
        var existing = Set<String>()
        for key in keys {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.uniqueKey == key })
            descriptor.fetchLimit = 1
            if try modelContext.fetch(descriptor).first != nil { existing.insert(key) }
        }

        var inserted = 0
        var skipped = 0
        var newest: [String: Date] = [:]
        var newestID: [String: String] = [:]

        for event in messages {
            let key = Message.uniqueKey(serverID: serverID, topic: event.topic, messageID: event.id)
            if existing.contains(key) { skipped += 1; continue }
            existing.insert(key)

            modelContext.insert(Message(
                serverID: serverID,
                topic: event.topic,
                messageID: event.id,
                time: event.date,
                expires: event.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                title: event.title,
                body: event.message ?? "",
                priority: event.priority ?? 3,
                tags: event.tags ?? [],
                click: event.click,
                iconURL: event.icon,
                contentType: event.contentType,
                actionsJSON: event.actions.flatMap { try? JSONEncoder().encode($0) }
            ))
            inserted += 1

            if newest[event.topic] == nil || event.date > newest[event.topic]! {
                newest[event.topic] = event.date
                newestID[event.topic] = event.id
            }
        }

        try advanceWatermarks(newest, ids: newestID, serverID: serverID)
        try modelContext.save()
        return InsertResult(inserted: inserted, duplicatesSkipped: skipped)
    }

    private func advanceWatermarks(_ newest: [String: Date], ids: [String: String],
                                   serverID: UUID) throws {
        for (topic, time) in newest {
            // Scoped to this server: two servers may both carry a topic of
            // the same name, and advancing the wrong one would make the other
            // resume from a point it never reached.
            guard let sub = try subscriptions(forServer: serverID)
                .first(where: { $0.topic == topic }) else { continue }
            // A late arrival must never rewind the watermark, or the next
            // reconnect would replay everything after the older message.
            if sub.lastMessageTime == nil || time > sub.lastMessageTime! {
                sub.lastMessageTime = time
                sub.lastMessageID = ids[topic]
            }
        }
    }

    public func watermarks(forServer serverID: UUID) throws -> [TopicWatermark] {
        try subscriptions(forServer: serverID).map(\.watermark)
    }

    public func caughtUpTo(forServer serverID: UUID) throws -> Date? {
        try server(serverID)?.caughtUpTo
    }

    public func setCaughtUpTo(_ date: Date, forServer serverID: UUID) throws {
        guard let server = try server(serverID) else { return }
        if server.caughtUpTo == nil || date > server.caughtUpTo! {
            server.caughtUpTo = date
            try modelContext.save()
        }
    }

    public func messages(forServer serverID: UUID, topic: String?,
                         limit: Int) throws -> [MessageSnapshot] {
        // The topic filter belongs IN the predicate. Applying `fetchLimit`
        // first and filtering afterwards would return fewer than `limit` rows
        // whenever other topics are interleaved — silently truncating a page.
        var descriptor: FetchDescriptor<Message>
        if let topic {
            descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.serverID == serverID && $0.topic == topic },
                sortBy: [SortDescriptor(\.time, order: .reverse)])
        } else {
            descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.serverID == serverID },
                sortBy: [SortDescriptor(\.time, order: .reverse)])
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    public func messageCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Message>())
    }

    private func server(_ id: UUID) throws -> Server? {
        var descriptor = FetchDescriptor<Server>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func subscriptions(forServer serverID: UUID) throws -> [Subscription] {
        guard let server = try server(serverID) else {
            // An unknown server id is a caller bug, not an empty result to
            // paper over. Falling back to every subscription would silently
            // mix one server's topics into another's watermarks.
            Log.store.error("no server record for the requested id")
            return []
        }
        return server.subscriptions
    }
}
```

- [ ] **Step 4: Run and verify**

```bash
swift test --filter MessageStoreTests 2>&1 | tail -30
swift test 2>&1 | tail -3
```

Three of these are negative or count-unchanged assertions: `replayingAnOverlappingWindowDoesNotDuplicateRows`, `anOlderMessageDoesNotRewindTheWatermark`, `keepaliveAndOpenEventsAreNotStored`. **Mutate and verify all three:**

- Remove the `existing.contains(key)` skip → the duplicate test must FAIL.
- Change the watermark guard to assign unconditionally → the rewind test must FAIL.
- Remove the `filter { $0.kind == .message }` → the keepalive test must FAIL.

Restore after each and confirm green. Report all three results.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: MessageStore with dedupe and watermark persistence"
```

---

### Task 7: Retention policy and pruning

**Files:**
- Create: `Sources/NtfyKit/Persistence/RetentionPolicy.swift`
- Modify: `Sources/NtfyKit/Persistence/MessageStore.swift` (add `prune`)
- Create: `Tests/NtfyKitTests/RetentionTests.swift`

**Interfaces:**
- Consumes: `MessageStore`, `Message`, `Attachment`.
- Produces:
  - `struct RetentionPolicy: Sendable, Equatable` — `maxAge: TimeInterval` (default 30 days), `maxMessagesPerTopic: Int` (default 10_000), `static let `default``.
  - `struct PruneResult: Sendable, Equatable` — `messagesDeleted: Int`, `attachmentFilesDeleted: Int`.
  - `MessageStore.prune(policy:now:attachmentsDirectory:) throws -> PruneResult`

- [ ] **Step 1: Write the failing tests**

`Tests/NtfyKitTests/RetentionTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import NtfyKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func event(_ id: String, topic: String = "alerts", ageDays: Double) -> NtfyEvent {
    let t = Int(now.addingTimeInterval(-ageDays * 86_400).timeIntervalSince1970)
    let json = """
    {"id":"\(id)","time":\(t),"event":"message","topic":"\(topic)","message":"m"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private func makeStore() throws -> (MessageStore, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()
    return (MessageStore(modelContainer: container), serverID)
}

@Test func pruningRemovesMessagesOlderThanMaxAge() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("old", ageDays: 40), event("new", ageDays: 1)],
                               serverID: serverID)
    let result = try await store.prune(
        policy: RetentionPolicy(maxAge: 30 * 86_400, maxMessagesPerTopic: 10_000),
        now: now, attachmentsDirectory: nil)
    #expect(result.messagesDeleted == 1)
    #expect(try await store.messageCount() == 1)
    let left = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(left.first?.messageID == "new")
}

@Test func pruningKeepsAtMostMaxMessagesPerTopicNewestFirst() async throws {
    let (store, serverID) = try makeStore()
    let events = (0..<10).map { event("m\($0)", ageDays: Double(10 - $0) * 0.1) }
    _ = try await store.insert(events, serverID: serverID)

    let result = try await store.prune(
        policy: RetentionPolicy(maxAge: 30 * 86_400, maxMessagesPerTopic: 4),
        now: now, attachmentsDirectory: nil)
    #expect(result.messagesDeleted == 6)
    #expect(try await store.messageCount() == 4)
}

/// The per-topic cap is PER TOPIC, not global.
@Test func theCountCapAppliesPerTopicNotAcrossTopics() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    context.insert(Subscription(topic: "deploys", server: server))
    try context.save()
    let store = MessageStore(modelContainer: container)

    _ = try await store.insert((0..<5).map { event("a\($0)", topic: "alerts", ageDays: Double(5 - $0) * 0.1) },
                               serverID: serverID)
    _ = try await store.insert((0..<5).map { event("d\($0)", topic: "deploys", ageDays: Double(5 - $0) * 0.1) },
                               serverID: serverID)

    _ = try await store.prune(policy: RetentionPolicy(maxAge: 30 * 86_400, maxMessagesPerTopic: 3),
                              now: now, attachmentsDirectory: nil)
    #expect(try await store.messageCount() == 6)  // 3 per topic, two topics
}

@Test func nothingIsDeletedWhenEverythingIsWithinPolicy() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", ageDays: 1), event("b", ageDays: 2)],
                               serverID: serverID)
    let result = try await store.prune(policy: .default, now: now, attachmentsDirectory: nil)
    #expect(result.messagesDeleted == 0)
    #expect(try await store.messageCount() == 2)
}

/// A pruned message takes its attachment file with it — otherwise the database
/// shrinks and the disk does not.
@Test func pruningDeletesTheAttachmentFileOnDisk() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ntfyme-prune-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("graph.png")
    try Data("png".utf8).write(to: file)

    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    let old = Message(serverID: serverID, topic: "alerts", messageID: "old",
                      time: now.addingTimeInterval(-40 * 86_400), body: "m",
                      attachment: Attachment(name: "graph.png",
                                             urlString: "https://example.com/graph.png",
                                             localFilename: "graph.png"))
    context.insert(old)
    try context.save()

    let store = MessageStore(modelContainer: container)
    let result = try await store.prune(policy: .default, now: now, attachmentsDirectory: dir)
    #expect(result.messagesDeleted == 1)
    #expect(result.attachmentFilesDeleted == 1)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter RetentionTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'RetentionPolicy' in scope`.

- [ ] **Step 3: Write the policy**

`Sources/NtfyKit/Persistence/RetentionPolicy.swift`:

```swift
import Foundation

/// Spec §8: keep N days AND at most M messages per topic, whichever bound is
/// hit first.
public struct RetentionPolicy: Sendable, Equatable {
    public let maxAge: TimeInterval
    public let maxMessagesPerTopic: Int

    public static let `default` = RetentionPolicy(maxAge: 30 * 86_400,
                                                  maxMessagesPerTopic: 10_000)

    public init(maxAge: TimeInterval, maxMessagesPerTopic: Int) {
        self.maxAge = maxAge
        self.maxMessagesPerTopic = maxMessagesPerTopic
    }
}

public struct PruneResult: Sendable, Equatable {
    public let messagesDeleted: Int
    public let attachmentFilesDeleted: Int
}
```

- [ ] **Step 4: Add `prune` to the store**

Append to `MessageStore`:

```swift
    /// Applies both retention bounds and deletes the attachment files of every
    /// pruned message. Runs at launch and daily thereafter (spec §8).
    ///
    /// - Parameter attachmentsDirectory: where downloaded files live. `nil`
    ///   skips file deletion, for tests and for a build with no downloader.
    @discardableResult
    public func prune(policy: RetentionPolicy, now: Date = Date(),
                      attachmentsDirectory: URL?) throws -> PruneResult {
        let cutoff = now.addingTimeInterval(-policy.maxAge)
        var doomed: [Message] = []

        let tooOld = FetchDescriptor<Message>(predicate: #Predicate { $0.time < cutoff })
        doomed.append(contentsOf: try modelContext.fetch(tooOld))

        let doomedKeys = Set(doomed.map(\.uniqueKey))
        let survivors = try modelContext.fetch(
            FetchDescriptor<Message>(sortBy: [SortDescriptor(\.time, order: .reverse)])
        ).filter { !doomedKeys.contains($0.uniqueKey) }

        var seenPerTopic: [String: Int] = [:]
        for message in survivors {
            let count = (seenPerTopic[message.topic] ?? 0) + 1
            seenPerTopic[message.topic] = count
            if count > policy.maxMessagesPerTopic { doomed.append(message) }
        }

        var filesDeleted = 0
        for message in doomed {
            if let directory = attachmentsDirectory,
               let filename = message.attachment?.localFilename {
                let url = directory.appendingPathComponent(filename)
                do {
                    try FileManager.default.removeItem(at: url)
                    filesDeleted += 1
                } catch CocoaError.fileNoSuchFile {
                    // Already gone: the row outlived its file. Not an error —
                    // the goal is that the file is absent, and it is.
                } catch {
                    Log.store.error("attachment file deletion failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            modelContext.delete(message)
        }

        try modelContext.save()
        return PruneResult(messagesDeleted: doomed.count, attachmentFilesDeleted: filesDeleted)
    }
```

Add a `store` category to `Log.swift` alongside the existing ones, and update that file's doc comment to cover the new site.

- [ ] **Step 5: Run and verify**

```bash
swift test --filter RetentionTests 2>&1 | tail -30
swift test 2>&1 | tail -3
```

`nothingIsDeletedWhenEverythingIsWithinPolicy` asserts a zero and an unchanged count. **Mutate and verify:** invert the age comparison (`$0.time > cutoff`), confirm it FAILS, restore, confirm it passes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: retention policy and pruning, including attachment files"
```

---

### Task 8: Ingest — connection events into the store

**Files:**
- Create: `Sources/NtfyKit/Persistence/Ingest.swift`
- Create: `Tests/NtfyKitTests/IngestTests.swift`

**Interfaces:**
- Consumes: `ServerConnection`, `MessageStore`.
- Produces: `public actor Ingest` with `init(store: MessageStore, batchWindow: Duration = .milliseconds(250))`, `func attach(_ connection: ServerConnection, serverID: UUID) -> Task<Void, Never>`, `var insertedCount: Int`.

- [ ] **Step 1: Write the failing tests**

`Tests/NtfyKitTests/IngestTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import NtfyKit

@Test func eventsFromAConnectionBecomeRows() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.minimalMessage)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake, sleeper: ManualSleeper())

    let ingest = Ingest(store: store)
    let pump = await ingest.attach(connection, serverID: serverID)
    defer { pump.cancel() }

    await connection.start()
    #expect(await waitUntil { (try? await store.messageCount()) == 1 })
    await connection.stop()
}

/// Ingest persists the caughtUpTo the connection derived, so a restart
/// resumes from it rather than replaying.
@Test func ingestPersistsTheCaughtUpToTime() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.minimalMessage))])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake, sleeper: ManualSleeper())

    let ingest = Ingest(store: store)
    let pump = await ingest.attach(connection, serverID: serverID)
    defer { pump.cancel() }

    await connection.start()
    #expect(await waitUntil { ((try? await store.caughtUpTo(forServer: serverID)) ?? nil) != nil })
    await connection.stop()
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter IngestTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'Ingest' in scope`.

- [ ] **Step 3: Write it**

`Sources/NtfyKit/Persistence/Ingest.swift`:

```swift
import Foundation

/// Drains a connection's event stream into the store.
///
/// Events are batched over a short window rather than written one at a time:
/// a reconnect replay can deliver thousands of lines at once, and one
/// transaction per message would be pathological.
public actor Ingest {
    private let store: MessageStore
    private let batchWindow: Duration
    public private(set) var insertedCount = 0

    public init(store: MessageStore, batchWindow: Duration = .milliseconds(250)) {
        self.store = store
        self.batchWindow = batchWindow
    }

    /// Starts pumping. The returned task runs until the stream ends or it is
    /// cancelled; the caller owns it.
    public func attach(_ connection: ServerConnection, serverID: UUID) -> Task<Void, Never> {
        Task { [store, batchWindow] in
            var batch: [NtfyEvent] = []
            var lastFlush = ContinuousClock.now

            for await event in connection.events {
                batch.append(event)
                let elapsed = ContinuousClock.now - lastFlush
                guard elapsed >= batchWindow || batch.count >= 500 else { continue }
                await self.flush(&batch, serverID: serverID)
                lastFlush = ContinuousClock.now
            }
            await self.flush(&batch, serverID: serverID)

            // The connection derived this from every line it saw, including
            // keepalives that produce no rows. Persisting it is what makes a
            // restart resume from §5.2's point rather than the oldest message.
            if let caughtUp = await connection.caughtUpTo {
                do { try await store.setCaughtUpTo(caughtUp, forServer: serverID) }
                catch { Log.store.error("caughtUpTo persist failed: \(error.localizedDescription, privacy: .public)") }
            }
            _ = store
        }
    }

    private func flush(_ batch: inout [NtfyEvent], serverID: UUID) async {
        guard !batch.isEmpty else { return }
        let events = batch
        batch.removeAll()
        do {
            let result = try await store.insert(events, serverID: serverID)
            insertedCount += result.inserted
        } catch {
            // Never silent: a failed write means messages are lost from the
            // archive even though they were delivered.
            Log.store.error("message batch insert failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

The `attach` body as written closes over `self` inside a detached `Task`; make sure the flush and `caughtUpTo` calls compile under strict concurrency, hopping back to the actor where needed. If the shape fights you, restructure so the pump loop is a `private func pump(...) async` on the actor and `attach` returns `Task { await self.pump(...) }` — that is cleaner and is the preferred form.

- [ ] **Step 4: Run and verify**

```bash
swift test --filter IngestTests 2>&1 | tail -20
swift test 2>&1 | tail -3
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: ingest connection events into the store in batches"
```

---

### Task 9: New-topic backfill

Spec §5: a brand-new topic has no watermark. Folding it into the shared stream would drag the resume point back and replay every topic. Instead it is backfilled by a one-shot poll for that topic alone, before the shared stream is rebuilt.

**Files:**
- Create: `Sources/NtfyKit/Persistence/Backfill.swift`
- Create: `Tests/NtfyKitTests/BackfillTests.swift`

**Interfaces:**
- Consumes: `NtfyEndpoint.pollRequest(topic:since:)`, `StreamClient`, `MessageStore`.
- Produces: `public struct Backfill: Sendable` with `init(endpoint: NtfyEndpoint, client: any StreamClient, store: MessageStore)` and `func run(topic: String, serverID: UUID) async throws -> Int` (returns rows inserted).

- [ ] **Step 1: Write the failing tests**

`Tests/NtfyKitTests/BackfillTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import NtfyKit

private func makeStore(topics: [String]) throws -> (ModelContainer, MessageStore, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    for t in topics { context.insert(Subscription(topic: t, server: server)) }
    try context.save()
    return (container, MessageStore(modelContainer: container), serverID)
}

private func message(_ id: String, topic: String, time: Int) -> NtfyEvent {
    let json = """
    {"id":"\(id)","time":\(time),"event":"message","topic":"\(topic)","message":"m"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

@Test func backfillStoresTheTopicsCachedHistory() async throws {
    let (_, store, serverID) = try makeStore(topics: ["newtopic"])
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(message("h1", topic: "newtopic", time: 100)),
        .event(message("h2", topic: "newtopic", time: 200)),
    ])

    let backfill = Backfill(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        client: fake, store: store)

    let inserted = try await backfill.run(topic: "newtopic", serverID: serverID)
    #expect(inserted == 2)
    #expect(try await store.messageCount() == 2)
}

/// It must be a one-shot POLL for that topic alone, not a shared stream —
/// otherwise it replays every other topic's history too.
@Test func backfillPollsOnlyTheOneTopic() async throws {
    let (_, store, serverID) = try makeStore(topics: ["newtopic", "other"])
    let fake = FakeStreamClient()
    await fake.enqueue([.event(message("h1", topic: "newtopic", time: 100))])

    let backfill = Backfill(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        client: fake, store: store)
    _ = try await backfill.run(topic: "newtopic", serverID: serverID)

    let url = await fake.lastRequest?.url?.absoluteString ?? ""
    #expect(url.contains("/newtopic/json"))
    #expect(url.contains("poll=1"))
    #expect(url.contains("since=all"))
    #expect(url.contains("other") == false)
}

/// After backfill the topic has a watermark, so the rebuilt shared stream
/// cannot drag the resume point to the epoch.
@Test func backfillLeavesTheTopicWithAWatermark() async throws {
    let (_, store, serverID) = try makeStore(topics: ["newtopic"])
    let fake = FakeStreamClient()
    await fake.enqueue([.event(message("h1", topic: "newtopic", time: 100)),
                        .event(message("h2", topic: "newtopic", time: 250))])

    let backfill = Backfill(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        client: fake, store: store)
    _ = try await backfill.run(topic: "newtopic", serverID: serverID)

    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.first(where: { $0.topic == "newtopic" })?.lastMessageTime
            == Date(timeIntervalSince1970: 250))
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter BackfillTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'Backfill' in scope`.

- [ ] **Step 3: Write it**

`Sources/NtfyKit/Persistence/Backfill.swift`:

```swift
import Foundation

/// One-shot history fetch for a newly added topic (spec §5).
///
/// It must poll the single topic, not the shared multi-topic stream: a topic
/// with no watermark would otherwise drag the shared resume point to the epoch
/// and replay every other topic's entire cached history.
public struct Backfill: Sendable {
    private let endpoint: NtfyEndpoint
    private let client: any StreamClient
    private let store: MessageStore

    public init(endpoint: NtfyEndpoint, client: any StreamClient, store: MessageStore) {
        self.endpoint = endpoint
        self.client = client
        self.store = store
    }

    /// Fetches and stores the topic's server-cached history. Returns the number
    /// of rows inserted. The topic's watermark is set as a side effect of the
    /// insert, which is what makes the subsequent stream rebuild safe.
    @discardableResult
    public func run(topic: String, serverID: UUID) async throws -> Int {
        let request = try endpoint.pollRequest(topic: topic, since: .all)
        var events: [NtfyEvent] = []

        for try await element in client.stream(request) {
            switch element {
            case .event(let event):
                if event.kind == .message { events.append(event) }
            case .skippedLine(let reason):
                Log.stream.debug("backfill skipped a line: \(reason, privacy: .public)")
            }
        }

        let result = try await store.insert(events, serverID: serverID)
        Log.store.info("backfilled \(result.inserted, privacy: .public) messages for a new topic")
        return result.inserted
    }
}
```

- [ ] **Step 4: Run and verify**

```bash
swift test --filter BackfillTests 2>&1 | tail -20
swift test 2>&1 | tail -3
```

`backfillPollsOnlyTheOneTopic` includes `#expect(url.contains("other") == false)` — a negative. **Mutate and verify:** change `pollRequest(topic:...)` to `streamRequest(topics: [topic, "other"], ...)`, confirm the test FAILS, restore.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: one-shot backfill for a newly added topic"
```

---

### Task 10: Connection diagnostics — make the history gap observable

Closes the item Stage 1–2 deferred. Spec §10 requires the gap be surfaced and "must never be mistaken for a clean resume", but it is currently a `.degraded` state overwritten by `.open` milliseconds later, so no consumer can ever see it. A one-shot diagnostic does not belong in a level-triggered state enum.

**Files:**
- Create: `Sources/NtfyKit/Networking/ConnectionDiagnostic.swift`
- Modify: `Sources/NtfyKit/Networking/ServerConnection.swift`
- Create: `Tests/NtfyKitTests/ConnectionDiagnosticTests.swift`

**Interfaces:**
- Consumes: `ServerConnection`, `DegradedReason`.
- Produces:
  - `enum ConnectionDiagnostic: Sendable, Equatable` — `.historyGap(since: Date)`, `.invalidSinceRejected`, `.skippedLine(reason: String)`, `.unauthorized`.
  - `ServerConnection.diagnostics: AsyncStream<ConnectionDiagnostic>` (eagerly created in `init`, same reasoning as `events`).
  - `ServerConnection.watermarkSnapshot() -> [TopicWatermark]` — closes the "watermarks are write-only" gap so persistence and the coordinator can read them.

- [ ] **Step 1: Write the failing tests**

`Tests/NtfyKitTests/ConnectionDiagnosticTests.swift`:

```swift
import Foundation
import Testing
@testable import NtfyKit

private func connection(_ fake: FakeStreamClient,
                        watermarks: [TopicWatermark]) -> ServerConnection {
    ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: watermarks, client: fake, sleeper: ManualSleeper())
}

/// The gap must survive the .open that immediately follows it.
@Test func aHistoryGapIsDeliveredAsADiagnosticNotJustATransientState() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])

    let stale = Date().addingTimeInterval(-48 * 3600)
    let c = connection(fake, watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: stale)])

    let seen = DiagnosticCollector()
    let consumer = Task { for await d in c.diagnostics { await seen.add(d) } }
    defer { consumer.cancel() }

    await c.start()
    #expect(await waitUntil { await seen.contains { if case .historyGap = $0 { return true }; return false } })
    // And the state has moved on to .open, proving the diagnostic outlived it.
    #expect(await waitUntil { await c.state == .open })
    await c.stop()
}

@Test func noGapIsReportedForARecentWatermark() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    let c = connection(fake, watermarks: [
        TopicWatermark(topic: "alerts", lastMessageTime: Date().addingTimeInterval(-60))])

    let seen = DiagnosticCollector()
    let consumer = Task { for await d in c.diagnostics { await seen.add(d) } }
    defer { consumer.cancel() }

    await c.start()
    #expect(await waitUntil { await c.state == .open })
    try await Task.sleep(for: .milliseconds(50))
    #expect(await seen.contains { if case .historyGap = $0 { return true }; return false } == false)
    await c.stop()
}

@Test func theWatermarkSnapshotReflectsReceivedMessages() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.minimalMessage))])
    let c = connection(fake, watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)])

    await c.start()
    #expect(await waitUntil { await c.watermarkSnapshot().first?.lastMessageTime != nil })
    #expect(await c.watermarkSnapshot().first?.lastMessageTime
            == Date(timeIntervalSince1970: 1_788_353_322))
    await c.stop()
}

actor DiagnosticCollector {
    private var items: [ConnectionDiagnostic] = []
    func add(_ d: ConnectionDiagnostic) { items.append(d) }
    func contains(_ predicate: (ConnectionDiagnostic) -> Bool) -> Bool { items.contains(where: predicate) }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter ConnectionDiagnosticTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'ConnectionDiagnostic' in scope`.

- [ ] **Step 3: Write the diagnostic type**

`Sources/NtfyKit/Networking/ConnectionDiagnostic.swift`:

```swift
import Foundation

/// One-shot facts about a connection that a level-triggered state enum cannot
/// carry, because the next state transition overwrites them.
///
/// `ConnectionState.degraded(.historyGap)` is replaced by `.open` as soon as
/// the first line arrives — typically within milliseconds — so a consumer
/// polling state can never observe it. Spec §10 requires the gap be surfaced,
/// so it is delivered here instead, where it is latched until read.
public enum ConnectionDiagnostic: Sendable, Equatable {
    /// The resume point predates the server's cache window, so the server is
    /// replaying its whole cache and some messages are unrecoverable.
    case historyGap(since: Date)
    /// The server rejected the `since` this client built; the next attempt
    /// falls back to `since=all`.
    case invalidSinceRejected
    /// A line could not be decoded. Never contains a message body.
    case skippedLine(reason: String)
    /// The credential was rejected; the connection will not retry.
    case unauthorized
}
```

- [ ] **Step 4: Emit them from `ServerConnection`**

Add, alongside the existing `events` stream and created the same eager way in `init`:

```swift
    private let diagnosticContinuation: AsyncStream<ConnectionDiagnostic>.Continuation
    public nonisolated let diagnostics: AsyncStream<ConnectionDiagnostic>
```

In `init`, mirror the `events` construction:

```swift
        var capturedDiagnostics: AsyncStream<ConnectionDiagnostic>.Continuation!
        self.diagnostics = AsyncStream { capturedDiagnostics = $0 }
        self.diagnosticContinuation = capturedDiagnostics
```

Then emit at each site: in `connectOnce` where `hasHistoryGap` is handled, yield `.historyGap(since:)` with the resolved date alongside the existing log; in the `invalidSince` catch, yield `.invalidSinceRejected`; where `.skippedLine` is logged, yield it; in the unauthorized branch, yield `.unauthorized`.

Add the snapshot accessor:

```swift
    /// Watermarks as currently known, for persistence and for rebuilding the
    /// connection after a topic is added. Previously write-only.
    public func watermarkSnapshot() -> [TopicWatermark] { watermarks }
```

- [ ] **Step 5: Run and verify**

```bash
swift test --filter ConnectionDiagnosticTests 2>&1 | tail -20
swift test 2>&1 | tail -3
```

`noGapIsReportedForARecentWatermark` asserts `== false`. **Mutate and verify:** make the gap emit unconditionally, confirm the test FAILS, restore, confirm it passes. Report both.

- [ ] **Step 6: Update the spec**

Spec §10's history-gap row and §5's `hasHistoryGap` discussion should now say the gap is delivered on the diagnostics stream, not only reflected in state. Remove the deferral comment in `ServerConnection` that pointed at §5.2 for this.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: deliver history gaps and skipped lines as latched diagnostics"
```

---

### Task 11: A `URLSession` configuration fit for long-lived streams

`URLSession.shared`'s defaults are wrong for this app in two ways. `timeoutIntervalForRequest` is 60s of inactivity, which is *shorter* than the 90s keepalive watchdog — so most stalls surface as a `URLError` rather than as the keepalive timeout the spec says is the primary signal. And `timeoutIntervalForResource` is 7 days, which silently ends every stream weekly.

**Files:**
- Create: `Sources/NtfyKit/Networking/StreamingSession.swift`
- Modify: `Sources/NtfyKit/Networking/NtfyStreamClient.swift` (default session)
- Create: tests in `Tests/NtfyKitTests/StreamClientSeamTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `enum StreamingSession { public static func make() -> URLSession }`, and `NtfyStreamClient.init(session: URLSession = StreamingSession.make())`.

- [ ] **Step 1: Write the failing tests**

Append to `StreamClientSeamTests.swift`:

```swift
@Test func theStreamingSessionOutlastsTheKeepaliveWatchdog() {
    let session = StreamingSession.make()
    // The watchdog fires at 90s. A request timeout shorter than that would
    // make URLError, not the keepalive gap, the primary liveness signal —
    // inverting what spec §5 says the design depends on.
    #expect(session.configuration.timeoutIntervalForRequest > 90)
}

@Test func theStreamingSessionDoesNotExpireLongLivedStreams() {
    let session = StreamingSession.make()
    // The default is 7 days, which silently ends every stream weekly.
    #expect(session.configuration.timeoutIntervalForResource >= 365 * 86_400)
}

@Test func theStreamingSessionWaitsForConnectivity() {
    #expect(StreamingSession.make().configuration.waitsForConnectivity == true)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter StreamClientSeamTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'StreamingSession' in scope`.

- [ ] **Step 3: Write it**

`Sources/NtfyKit/Networking/StreamingSession.swift`:

```swift
import Foundation

/// A `URLSession` configured for connections that are supposed to stay open
/// for days.
///
/// `URLSession.shared` is wrong here in two ways. Its 60-second
/// `timeoutIntervalForRequest` is shorter than the 90-second keepalive
/// watchdog, so a stalled connection surfaces as a `URLError` before the
/// watchdog can classify it — inverting the primary liveness signal spec §5
/// specifies. And its 7-day `timeoutIntervalForResource` would end every
/// stream weekly for no reason the user could see.
public enum StreamingSession {
    public static func make() -> URLSession {
        let configuration = URLSessionConfiguration.default
        // Comfortably longer than the watchdog, so the watchdog decides.
        configuration.timeoutIntervalForRequest = 300
        // Effectively unbounded: the stream ends when the app or server says so.
        configuration.timeoutIntervalForResource = 365 * 86_400
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
```

Change `NtfyStreamClient.init`'s default from `session: URLSession = .shared` to `session: URLSession = StreamingSession.make()`.

- [ ] **Step 4: Run and verify**

```bash
swift test 2>&1 | tail -3
```

Expected: all tests pass. Watch for slowdowns — `waitsForConnectivity` changes behavior when a connection is refused, which the `MockNtfyServer` error-path tests exercise. If any test now hangs where it used to fail fast, that is a finding: report it rather than lengthening a timeout.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: URLSession configuration suited to long-lived streams"
```

---

## Definition of Done for Stage 3

- Messages received by a connection are persisted, deduplicated by `uniqueKey`, and survive a restart.
- Watermarks and `caughtUpTo` persist; a restart resumes from §5.2's point rather than replaying.
- A newly added topic is backfilled without dragging the shared resume point back.
- Retention prunes by age and per-topic count, and takes attachment files with it.
- History gaps are observable on a diagnostics stream, not only as a transient state.
- `NtfyKit` still imports no UI framework, and no `@Model` instance crosses an actor boundary.
- Every negative assertion in this plan has been run against a deliberately broken build.
- Full suite green, zero warnings, CI green on `macos-26`.

## What this plan deliberately does not build

- **Plan 3 (Stage 4):** `ConnectionCoordinator` with sleep/wake and network-path triggers, notification presentation, menu bar popover, History window, Settings, attachment downloading.
- **Plan 4 (Stage 5):** compose sheet, attachment upload, Developer ID signing and notarization.

Carried forward, recorded but not fixed here:
- `Retry-After` is parsed only as delta-seconds; a legal HTTP-date form silently becomes `nil`.
- `.httpError` has no test coverage.
- The unknown-event-type log value is bounded in length but not sanitized for newlines, so a hostile server operator could break a line in `log stream`.
- `events` is never finished, and a `ServerConnection` is bound to one credential for its lifetime; changing credentials requires building a new instance.
