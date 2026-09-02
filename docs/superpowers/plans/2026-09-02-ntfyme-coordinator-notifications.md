# NtfyMe Coordinator and Notifications Implementation Plan (Stage 4a)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the library into an app that actually works — servers are loaded from the store, connected, kept alive across sleep and network changes, and every message that clears the suppression rules raises a native notification.

**Architecture:** A `ConnectionCoordinator` in `NtfyKit` owns one `ServerConnection` per persisted server, seeds each from the store, and reconnects on network-path changes. The AppKit-only half — sleep/wake — lives in the app target and calls into it. Notification *decisions* are a pure, fully tested function in `NtfyKit` producing a `Sendable` value; only the thin translation of that value into `UNUserNotificationCenter` lives in the app target, where it cannot be unit tested.

**Tech Stack:** Swift 6.2, SwiftData, Network.framework, UserNotifications, AppKit (app target only), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-mac-ntfy-design.md` — implements §5's `ConnectionCoordinator`, all of §6, §8's pruning schedule, and the launch-at-login part of §7. Read §5, §5.2, §6 and §8 before starting.

**Previous plans:** `2026-09-02-ntfyme-foundation.md` (Stages 1–2) and `2026-09-02-ntfyme-persistence.md` (Stage 3), both merged. Their measured-behavior tables still apply.

## Global Constraints

- **Product `NtfyMe`, bundle id `dev.aloi.NtfyMe`, MIT.** Platform floor macOS 26.
- **Toolchain:** `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` before every `swift` command, or `import Testing` fails to resolve project-wide. Never `sudo xcode-select`. `timeout`/`gtimeout` are NOT installed — bound test runs with your agent's own timeout mechanism.
- **The repository is public** (github.com/ctaloi/ntfyme). No credentials, tokens, personal server URLs, personal topic names, internal hostnames, or signing material in any committed file — fixtures included.
- **`NtfyKit` imports no UI framework.** No AppKit, no SwiftUI, and **no UserNotifications** — the notification decision is a value type; only the app target talks to `UNUserNotificationCenter`. Network.framework, SwiftData and `os` are fine. A reviewer should reject any task that breaks this.
- **Swift 6 strict concurrency.** No `@Model` instance crosses an actor boundary; the store's API is value types only.
- **No silent failures.** Never `try?` away an error without a comment justifying **why it cannot fail** — not that it is unlikely. Four separate violations of this were found across the previous two stages.
- **Message bodies, topic names, `messageID`s and filenames are sensitive.** `Sources/NtfyKit/Log.swift`'s doc comment is the authority on what each site may interpolate; `serverID.uuidString` and fixed constants are permitted, `error.localizedDescription` is banned. **A notification's own title and body are the exception** — they are shown to the user by design — but they must still never reach a *log*.
- **Every wait bounded**, and a test must fail rather than hang on regression. Use the shared `waitUntil`; add `.timeLimit` to any test that could stall.
- Test output pristine — warnings are findings.

### The test rule this plan exists under

The previous two stages found **seven** tests that stated an invariant their assertions never touched — all negative assertions never demonstrated able to fail. **Any test whose only assertion is `== false`, `== nil`, `isEmpty`, or a count that did not change MUST be run once against a deliberately broken build before it is accepted.** Report both results. This plan is full of "no notification was raised" assertions, which is exactly that shape.

## Inherited facts these tasks depend on

| Fact | Consequence |
|---|---|
| `ServerConnection` has **no production construction site** — `grep "ServerConnection("` finds tests only | Task 1 is the first real one, and it is what physically closes Stage 3's resume loop |
| `ServerConnection.init` takes `caughtUpTo: Date? = nil`; it is **not** read from the store by anything yet | Task 1 must seed it, or a quiet topic replays its whole cache on every launch |
| `events` is a **mixed message/keepalive stream** since Stage 3 | Every consumer must filter `kind == .message`. `MessageStore.insert` already does |
| Only `keepalive` proves delivery; `open` precedes ntfy's replay | Do not reintroduce any "any line advances progress" logic |
| `Subscription` carries `muted` and `minAlertPriority`; `Server` carries `caughtUpTo` and `cacheWindowSeconds` | Suppression reads these; Task 5 does not invent new storage for them |
| `com.apple.developer.usernotifications.time-sensitive` **cannot be signed with a local Apple Development identity** — the app is killed at launch (AMFI, no provisioning profile). Measured Stage 1 | Priorities 4–5 degrade to `.active` in development. Do not add the entitlement to the local build |

## File Structure

```
Sources/NtfyKit/
  Connection/ConnectionCoordinator.swift    NEW  one connection per server; path monitor; reconnectAll
  Connection/ServerRecordSnapshot.swift     NEW  Sendable view of a Server row, for building a connection
  Persistence/MessageStore.swift            MOD  add servers() -> [ServerRecordSnapshot]
  Notifications/NotificationDecision.swift  NEW  pure: message + settings -> present or suppress
  Notifications/NotificationRequest.swift   NEW  Sendable description of what to present
  Notifications/NotificationAction.swift    NEW  Sendable view of an ntfy action, minus broadcast
  Preferences.swift                         NEW  UserDefaults-backed global settings

Sources/NtfyMe/
  AppDelegate.swift                         MOD  build the graph; sleep/wake bridge
  NotificationPresenter.swift               NEW  NotificationRequest -> UNUserNotificationCenter
  NotificationActionHandler.swift           NEW  view / copy / http, and body activation
  LoginItem.swift                           NEW  SMAppService wrapper
  RetentionScheduler.swift                  NEW  prune at launch and daily

Tests/NtfyKitTests/
  ConnectionCoordinatorTests.swift          NEW
  NotificationDecisionTests.swift           NEW
  PreferencesTests.swift                    NEW
  Support/FakePathMonitor.swift             NEW
```

---

### Task 1: `ServerRecordSnapshot` and `MessageStore.servers()`

Nothing can currently ask the store what servers exist. This is the first half of closing Stage 3's open loop.

**Files:**
- Create: `Sources/NtfyKit/Connection/ServerRecordSnapshot.swift`
- Modify: `Sources/NtfyKit/Persistence/MessageStore.swift`
- Create: `Tests/NtfyKitTests/ConnectionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Server`, `Subscription`, `TopicWatermark`, `MessageStore`.
- Produces:
  - `struct ServerRecordSnapshot: Sendable, Equatable, Identifiable` — `id: UUID`, `name: String`, `baseURL: URL`, `authKindRaw: String`, `caughtUpTo: Date?`, `cacheWindowSeconds: Double`, `watermarks: [TopicWatermark]`, `sortOrder: Int`. Computed `topics: [String]`.
  - `MessageStore.servers() throws -> [ServerRecordSnapshot]`, sorted by `sortOrder`.

- [ ] **Step 1: Write the failing test**

`Tests/NtfyKitTests/ConnectionCoordinatorTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import NtfyKit

@Test func theStoreReportsItsServersAsSendableSnapshots() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let a = Server(name: "Alpha", baseURLString: "https://a.example.com", sortOrder: 1)
    let b = Server(name: "Beta", baseURLString: "https://b.example.com", sortOrder: 0)
    context.insert(a); context.insert(b)
    context.insert(Subscription(topic: "alerts", server: a,
                                lastMessageTime: Date(timeIntervalSince1970: 100)))
    context.insert(Subscription(topic: "deploys", server: a))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let servers = try await store.servers()

    #expect(servers.map(\.name) == ["Beta", "Alpha"])          // sortOrder, not insertion
    let alpha = try #require(servers.first { $0.name == "Alpha" })
    #expect(alpha.baseURL == URL(string: "https://a.example.com"))
    #expect(Set(alpha.topics) == ["alerts", "deploys"])
    #expect(alpha.watermarks.first { $0.topic == "alerts" }?.lastMessageTime
            == Date(timeIntervalSince1970: 100))
    #expect(alpha.watermarks.first { $0.topic == "deploys" }?.lastMessageTime == nil)
}

/// caughtUpTo must survive the round trip, or a restart replays every quiet
/// topic's whole cache — the defect Stage 3 exists to remove.
@Test func aServerSnapshotCarriesItsPersistedCaughtUpTo() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    let server = Server(id: id, name: "Alpha", baseURLString: "https://a.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let mark = Date(timeIntervalSince1970: 1_788_353_322)
    try await store.setCaughtUpTo(mark, forServer: id)

    let snapshot = try #require(try await store.servers().first)
    #expect(snapshot.caughtUpTo == mark)
}

/// A server with a malformed URL is a corrupt row, not a crash.
@Test func aServerWithAnUnparseableURLIsSkippedNotFatal() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    context.insert(Server(name: "Broken", baseURLString: ""))
    let ok = Server(name: "Fine", baseURLString: "https://a.example.com")
    context.insert(ok)
    context.insert(Subscription(topic: "alerts", server: ok))
    try context.save()

    let servers = try await MessageStore(modelContainer: container).servers()
    #expect(servers.map(\.name) == ["Fine"])
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --filter ConnectionCoordinatorTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'ServerRecordSnapshot' in scope` / no `servers()`.

- [ ] **Step 3: Write the snapshot type**

`Sources/NtfyKit/Connection/ServerRecordSnapshot.swift`:

```swift
import Foundation

/// A `Sendable` view of one `Server` row and its subscriptions.
///
/// `@Model` classes are not `Sendable` and must not cross an actor boundary,
/// so the coordinator is handed one of these rather than a `Server`.
public struct ServerRecordSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let authKindRaw: String
    /// §5.2's resume point, as persisted. Seeding a new connection with this is
    /// what stops a quiet topic replaying its whole cache on every launch.
    public let caughtUpTo: Date?
    public let cacheWindowSeconds: Double
    public let watermarks: [TopicWatermark]
    public let sortOrder: Int

    public var topics: [String] { watermarks.map(\.topic) }

    public init(id: UUID, name: String, baseURL: URL, authKindRaw: String,
                caughtUpTo: Date?, cacheWindowSeconds: Double,
                watermarks: [TopicWatermark], sortOrder: Int) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authKindRaw = authKindRaw
        self.caughtUpTo = caughtUpTo
        self.cacheWindowSeconds = cacheWindowSeconds
        self.watermarks = watermarks
        self.sortOrder = sortOrder
    }
}
```

- [ ] **Step 4: Add `servers()` to the store**

Append to `MessageStore`:

```swift
    /// Every configured server, as `Sendable` snapshots, ordered by `sortOrder`.
    ///
    /// A row whose `baseURLString` does not parse is skipped and logged rather
    /// than throwing: one corrupt row must not stop every other server from
    /// connecting.
    public func servers() throws -> [ServerRecordSnapshot] {
        let rows = try modelContext.fetch(
            FetchDescriptor<Server>(sortBy: [SortDescriptor(\.sortOrder)]))

        return rows.compactMap { row in
            guard let url = row.baseURL else {
                Log.store.error("skipping a server row whose base URL does not parse")
                return nil
            }
            return ServerRecordSnapshot(
                id: row.id, name: row.name, baseURL: url,
                authKindRaw: row.authKindRaw, caughtUpTo: row.caughtUpTo,
                cacheWindowSeconds: row.cacheWindowSeconds,
                watermarks: row.subscriptions.map(\.watermark),
                sortOrder: row.sortOrder)
        }
    }
```

- [ ] **Step 5: Run to verify it passes**

```bash
swift test --filter ConnectionCoordinatorTests 2>&1 | tail -20
swift test 2>&1 | tail -3
```

Expected: 3 new pass; all 134 prior still pass.

`aServerWithAnUnparseableURLIsSkippedNotFatal` asserts an absence. **Mutate:** change the `guard let url` to force-unwrap with a fallback URL so the broken row is included; confirm the test FAILS; restore. Report both.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: expose configured servers as Sendable snapshots"
```

---

### Task 2: `ConnectionCoordinator`

**Files:**
- Create: `Sources/NtfyKit/Connection/ConnectionCoordinator.swift`, `Tests/NtfyKitTests/Support/FakePathMonitor.swift`
- Modify: `Tests/NtfyKitTests/ConnectionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ServerRecordSnapshot`, `MessageStore`, `ServerConnection`, `Ingest`, `NtfyEndpoint`, `AuthCredential`, `KeychainStore`, `StreamClient`.
- Produces:
  - `protocol PathMonitoring: Sendable { func start(onSatisfied: @Sendable @escaping () async -> Void) ; func cancel() }`
  - `struct SystemPathMonitor: PathMonitoring` (wraps `NWPathMonitor`).
  - `actor ConnectionCoordinator` with `init(store:keychain:client:pathMonitor:ingest:)`, `func start() async`, `func stop() async`, `func reconnectAll() async`, `var connectionCount: Int`, `func state(forServer: UUID) async -> ConnectionState?`.

- [ ] **Step 1: Write the fake and the failing tests**

`Tests/NtfyKitTests/Support/FakePathMonitor.swift`:

```swift
import Foundation
@testable import NtfyKit

/// Deterministic `PathMonitoring`. `simulatePathSatisfied()` fires the callback
/// exactly once per call, so a test drives network changes rather than waiting
/// for a real interface to flap.
actor FakePathMonitor: PathMonitoring {
    private var handler: (@Sendable () async -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    nonisolated func start(onSatisfied: @Sendable @escaping () async -> Void) {
        Task { await self.store(onSatisfied) }
    }

    nonisolated func cancel() {
        Task { await self.recordCancel() }
    }

    private func store(_ h: @Sendable @escaping () async -> Void) {
        handler = h
        startCount += 1
    }

    private func recordCancel() {
        handler = nil
        cancelCount += 1
    }

    func simulatePathSatisfied() async {
        await handler?()
    }
}
```

Append to `ConnectionCoordinatorTests.swift`:

```swift
private func seededStore(topics: [String] = ["alerts"]) throws -> (ModelContainer, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    let server = Server(id: id, name: "Alpha", baseURLString: "https://a.example.com")
    context.insert(server)
    for t in topics { context.insert(Subscription(topic: t, server: server)) }
    try context.save()
    return (container, id)
}

@Test func startingTheCoordinatorOpensOneConnectionPerServer() async throws {
    let (container, _) = try seededStore()
    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])

    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: FakePathMonitor(),
        ingest: Ingest(store: store))

    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 1 })
    #expect(await coordinator.connectionCount == 1)
    await coordinator.stop()
}

/// The whole point of Stage 3's caughtUpTo work: a restart must resume from the
/// persisted point, not replay from the oldest message.
@Test func aConnectionIsSeededWithThePersistedCaughtUpTo() async throws {
    let (container, id) = try seededStore()
    let store = MessageStore(modelContainer: container)
    // Watermark 24h old; caughtUpTo only 2 minutes old.
    let context = ModelContext(container)
    let sub = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
    sub.lastMessageTime = Date().addingTimeInterval(-86_400)
    try context.save()
    let recent = Date().addingTimeInterval(-120)
    try await store.setCaughtUpTo(recent, forServer: id)

    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: FakePathMonitor(),
        ingest: Ingest(store: store))

    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 1 })

    let url = try #require(await fake.lastRequest?.url?.absoluteString)
    let since = Int(recent.timeIntervalSince1970) - 5
    #expect(url.contains("since=\(since)"))
    await coordinator.stop()
}

/// A network path coming back must reconnect immediately, not wait out backoff.
@Test func aSatisfiedNetworkPathReconnectsEveryConnection() async throws {
    let (container, _) = try seededStore()
    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    let monitor = FakePathMonitor()

    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: monitor, ingest: Ingest(store: store))

    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 1 })
    let before = await fake.requestCount

    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    await monitor.simulatePathSatisfied()

    #expect(await waitUntil { await fake.requestCount > before })
    await coordinator.stop()
}

@Test func stoppingCancelsTheMonitorAndEveryConnection() async throws {
    let (container, id) = try seededStore()
    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    let monitor = FakePathMonitor()

    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: monitor, ingest: Ingest(store: store))
    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 1 })

    await coordinator.stop()
    #expect(await coordinator.connectionCount == 0)
    #expect(await waitUntil { await monitor.cancelCount == 1 })
    #expect(await coordinator.state(forServer: id) == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter ConnectionCoordinatorTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'ConnectionCoordinator' in scope`.

- [ ] **Step 3: Write the path monitor abstraction**

At the top of `Sources/NtfyKit/Connection/ConnectionCoordinator.swift`:

```swift
import Foundation
import Network

/// Indirection over `NWPathMonitor` so a test can drive network changes.
public protocol PathMonitoring: Sendable {
    func start(onSatisfied: @Sendable @escaping () async -> Void)
    func cancel()
}

/// Fires whenever the system path becomes satisfied — the signal that a
/// reconnect should happen immediately rather than waiting out backoff.
public struct SystemPathMonitor: PathMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.aloi.NtfyMe.path")

    public init() {}

    public func start(onSatisfied: @Sendable @escaping () async -> Void) {
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { await onSatisfied() }
        }
        monitor.start(queue: queue)
    }

    public func cancel() { monitor.cancel() }
}
```

- [ ] **Step 4: Write the coordinator**

Append to the same file:

```swift
/// Owns one `ServerConnection` per configured server.
///
/// This is the first production construction site for `ServerConnection`, and
/// it is what closes §5.2's loop: each connection is seeded with the watermarks
/// and `caughtUpTo` the store persisted, so a restart resumes rather than
/// replaying every quiet topic's cache.
///
/// Sleep and wake are NOT handled here — `NSWorkspace` is AppKit and `NtfyKit`
/// imports no UI framework. The app target observes those and calls
/// `reconnectAll()`.
public actor ConnectionCoordinator {
    private struct Live {
        let connection: ServerConnection
        let pump: Task<Void, Never>
    }

    private let store: MessageStore
    private let keychain: KeychainStore
    private let client: any StreamClient
    private let pathMonitor: any PathMonitoring
    private let ingest: Ingest

    private var live: [UUID: Live] = [:]

    public init(store: MessageStore, keychain: KeychainStore,
                client: any StreamClient, pathMonitor: any PathMonitoring,
                ingest: Ingest) {
        self.store = store
        self.keychain = keychain
        self.client = client
        self.pathMonitor = pathMonitor
        self.ingest = ingest
    }

    public var connectionCount: Int { live.count }

    public func state(forServer id: UUID) async -> ConnectionState? {
        guard let entry = live[id] else { return nil }
        return await entry.connection.state
    }

    public func start() async {
        let snapshots: [ServerRecordSnapshot]
        do {
            snapshots = try await store.servers()
        } catch {
            let ns = error as NSError
            Log.connection.error("could not load servers: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return
        }

        for snapshot in snapshots where !snapshot.topics.isEmpty {
            await open(snapshot)
        }

        pathMonitor.start { [weak self] in
            await self?.reconnectAll()
        }
    }

    private func open(_ snapshot: ServerRecordSnapshot) async {
        guard live[snapshot.id] == nil else { return }

        let credential: AuthCredential
        do {
            credential = try keychain.load(forServer: snapshot.id)
        } catch {
            // A credential that cannot be read is not a reason to skip the
            // server: an unauthenticated attempt gets a 401 the user can see,
            // which is more useful than silence.
            Log.connection.error("keychain read failed for server \(snapshot.id.uuidString, privacy: .public)")
            credential = .unauthenticated
        }

        let connection = ServerConnection(
            endpoint: NtfyEndpoint(baseURL: snapshot.baseURL, credential: credential),
            watermarks: snapshot.watermarks,
            caughtUpTo: snapshot.caughtUpTo,
            client: client,
            cacheWindow: snapshot.cacheWindowSeconds)

        let pump = await ingest.attach(connection, serverID: snapshot.id)
        await connection.start()
        live[snapshot.id] = Live(connection: connection, pump: pump)
    }

    /// Called on wake from sleep and when the network path becomes satisfied.
    /// Bypasses any pending backoff.
    public func reconnectAll() async {
        for entry in live.values {
            await entry.connection.reconnectNow()
        }
    }

    public func stop() async {
        pathMonitor.cancel()
        for entry in live.values {
            entry.pump.cancel()
            await entry.connection.stop()
        }
        live.removeAll()
    }
}
```

- [ ] **Step 5: Run and verify**

```bash
swift test --filter ConnectionCoordinatorTests 2>&1 | tail -20
swift test 2>&1 | tail -3
```

`stoppingCancelsTheMonitorAndEveryConnection` asserts a zero and a nil. **Mutate:** remove `live.removeAll()`; confirm it FAILS; restore. Report both.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: coordinator owning one connection per server, seeded from the store"
```

---

### Task 3: `Preferences` — the global settings the decision needs

**Files:**
- Create: `Sources/NtfyKit/Preferences.swift`, `Tests/NtfyKitTests/PreferencesTests.swift`

**Interfaces:**
- Consumes: `RetentionPolicy`.
- Produces: `struct Preferences: Sendable, Equatable` — `recordOnlyNeverAlert: Bool`, `retention: RetentionPolicy`, `launchAtLogin: Bool`. `final class PreferencesStore: Sendable` with `init(defaults: UserDefaults)`, `load() -> Preferences`, `save(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import NtfyKit

private func isolatedDefaults() -> UserDefaults {
    // A per-test suite name so tests never read or write the real app domain.
    UserDefaults(suiteName: "dev.aloi.NtfyMe.tests.\(UUID().uuidString)")!
}

@Test func defaultsMatchTheSpec() {
    let prefs = PreferencesStore(defaults: isolatedDefaults()).load()
    #expect(prefs.recordOnlyNeverAlert == false)
    #expect(prefs.retention == .default)          // 30 days / 10_000 per topic
    #expect(prefs.launchAtLogin == false)
}

@Test func preferencesRoundTrip() {
    let store = PreferencesStore(defaults: isolatedDefaults())
    let prefs = Preferences(
        recordOnlyNeverAlert: true,
        retention: RetentionPolicy(maxAge: 7 * 86_400, maxMessagesPerTopic: 500),
        launchAtLogin: true)
    store.save(prefs)
    #expect(store.load() == prefs)
}

/// A stored value of zero or less is corrupt, not "keep nothing".
@Test func nonsensicalStoredRetentionFallsBackToTheDefault() {
    let defaults = isolatedDefaults()
    defaults.set(0.0, forKey: "retention.maxAge")
    defaults.set(0, forKey: "retention.maxMessagesPerTopic")
    let prefs = PreferencesStore(defaults: defaults).load()
    #expect(prefs.retention == .default)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter PreferencesTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'PreferencesStore' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// App-wide settings. Per-topic settings live on `Subscription` in the store;
/// only what is genuinely global is here.
public struct Preferences: Sendable, Equatable {
    /// Spec §6's global suppression: persist every message, raise nothing.
    public var recordOnlyNeverAlert: Bool
    public var retention: RetentionPolicy
    public var launchAtLogin: Bool

    public static let `default` = Preferences(
        recordOnlyNeverAlert: false, retention: .default, launchAtLogin: false)

    public init(recordOnlyNeverAlert: Bool, retention: RetentionPolicy, launchAtLogin: Bool) {
        self.recordOnlyNeverAlert = recordOnlyNeverAlert
        self.retention = retention
        self.launchAtLogin = launchAtLogin
    }
}

/// `UserDefaults`-backed storage for `Preferences`.
public final class PreferencesStore: Sendable {
    private enum Key {
        static let recordOnly = "recordOnlyNeverAlert"
        static let maxAge = "retention.maxAge"
        static let maxPerTopic = "retention.maxMessagesPerTopic"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Preferences {
        let age = defaults.double(forKey: Key.maxAge)
        let perTopic = defaults.integer(forKey: Key.maxPerTopic)
        // Zero means either "never written" or a corrupt value; both take the
        // default. A retention window of zero would delete everything on the
        // next prune, which is never what a user meant.
        let retention = (age > 0 && perTopic > 0)
            ? RetentionPolicy(maxAge: age, maxMessagesPerTopic: perTopic)
            : .default

        return Preferences(
            recordOnlyNeverAlert: defaults.bool(forKey: Key.recordOnly),
            retention: retention,
            launchAtLogin: defaults.bool(forKey: Key.launchAtLogin))
    }

    public func save(_ prefs: Preferences) {
        defaults.set(prefs.recordOnlyNeverAlert, forKey: Key.recordOnly)
        defaults.set(prefs.retention.maxAge, forKey: Key.maxAge)
        defaults.set(prefs.retention.maxMessagesPerTopic, forKey: Key.maxPerTopic)
        defaults.set(prefs.launchAtLogin, forKey: Key.launchAtLogin)
    }
}
```

- [ ] **Step 4: Run and verify**

```bash
swift test --filter PreferencesTests 2>&1 | tail -20
swift test 2>&1 | tail -3
```

`defaultsMatchTheSpec` asserts `false` twice. **Mutate:** flip `recordOnlyNeverAlert`'s default to `true`; confirm FAIL; restore. Report both.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: UserDefaults-backed global preferences"
```

---

### Task 4: `NotificationDecision` — the pure rule

Every suppression and mapping rule in spec §6, as a function with no framework dependency. This is where the notification logic is actually *tested*; the app target's job is only to hand the result to the system.

**Files:**
- Create: `Sources/NtfyKit/Notifications/NotificationAction.swift`, `Sources/NtfyKit/Notifications/NotificationRequest.swift`, `Sources/NtfyKit/Notifications/NotificationDecision.swift`
- Create: `Tests/NtfyKitTests/NotificationDecisionTests.swift`

**Interfaces:**
- Consumes: `NtfyEvent`, `NtfyPriority`, `NtfyAction`, `Preferences`.
- Produces:
  - `enum NotificationInterruption: Sendable, Equatable` — `.passive`, `.active`, `.timeSensitive`.
  - `struct PresentableAction: Sendable, Equatable` — `id`, `title`, `kind` (`.view(url:)`, `.copy(value:)`, `.http(url:method:headers:body:)`).
  - `struct NotificationRequest: Sendable, Equatable` — `identifier`, `threadIdentifier`, `title`, `body`, `interruption`, `playsSound`, `categoryIdentifier: String?`, `actions: [PresentableAction]`, `clickURL: URL?`, `attachmentURL: URL?`.
  - `struct TopicAlertSettings: Sendable, Equatable` — `muted: Bool`, `minAlertPriority: Int`.
  - `enum NotificationDecision: Sendable, Equatable` — `.present(NotificationRequest)`, `.suppress(Reason)` with `Reason` = `.notAMessage`, `.globallySilenced`, `.topicMuted`, `.belowTopicThreshold`.
  - `NotificationDecision.decide(event:serverID:settings:preferences:) -> NotificationDecision`.

- [ ] **Step 1: Write the failing tests**

```swift
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
        event: message(priority: 3, title: nil, topic: "deploys"), serverID: sid,
        settings: unmuted, preferences: .default) else { Issue.record("suppressed"); return }
    #expect(r.title == "deploys")
    #expect(r.body == "B")
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter NotificationDecisionTests 2>&1 | tail -20
```

Expected: build error — `cannot find 'NotificationDecision' in scope`.

- [ ] **Step 3: Write the value types**

`Sources/NtfyKit/Notifications/NotificationAction.swift`:

```swift
import Foundation

/// An ntfy action this app can actually perform.
///
/// `broadcast` is deliberately absent: it is an Android intent and has no
/// meaning on macOS. Rendering it as a button that does nothing is worse than
/// omitting it, so it is dropped at decision time (spec §6).
public struct PresentableAction: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case view(url: URL)
        case copy(value: String)
        case http(url: URL, method: String, headers: [String: String], body: String?)
    }

    public let id: String
    public let title: String
    public let kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}
```

`Sources/NtfyKit/Notifications/NotificationRequest.swift`:

```swift
import Foundation

/// How urgently macOS should interrupt for a notification.
///
/// There is deliberately no `.critical`: it needs an entitlement Apple grants
/// only by individual application (spec §6). Note also that `.timeSensitive`
/// needs an entitlement that cannot be signed with a local development
/// identity, so priorities 4 and 5 degrade to `.active` in development builds.
public enum NotificationInterruption: Sendable, Equatable {
    case passive
    case active
    case timeSensitive
}

/// Everything the app target needs to build a `UNNotificationRequest`.
///
/// This type is the seam that keeps `UserNotifications` out of `NtfyKit`: every
/// rule in spec §6 is decided here and tested as a pure function, and the app
/// target only translates.
public struct NotificationRequest: Sendable, Equatable {
    public let identifier: String
    public let threadIdentifier: String
    public let title: String
    public let body: String
    public let interruption: NotificationInterruption
    public let playsSound: Bool
    /// `nil` when the message has no actions — no category needs registering.
    public let categoryIdentifier: String?
    public let actions: [PresentableAction]
    /// Opened when the notification body is clicked, if set.
    public let clickURL: URL?
    /// Remote URL of an image attachment, if the message had one. Downloading
    /// it is the app target's job and is out of scope for this plan.
    public let attachmentURL: URL?
}
```

- [ ] **Step 4: Write the decision**

`Sources/NtfyKit/Notifications/NotificationDecision.swift`:

```swift
import Foundation

/// Per-topic alert settings, read from the `Subscription` row.
public struct TopicAlertSettings: Sendable, Equatable {
    public let muted: Bool
    public let minAlertPriority: Int

    public init(muted: Bool, minAlertPriority: Int) {
        self.muted = muted
        self.minAlertPriority = minAlertPriority
    }
}

/// Whether an event should raise a notification, and exactly what it should
/// look like. A pure function of the event and the settings — no framework,
/// no I/O, no clock.
public enum NotificationDecision: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case notAMessage
        case globallySilenced
        case topicMuted
        case belowTopicThreshold
    }

    case present(NotificationRequest)
    case suppress(Reason)

    /// ntfy allows at most three action buttons; more is a malformed message.
    private static let maxActions = 3

    public static func decide(event: NtfyEvent, serverID: UUID,
                              settings: TopicAlertSettings,
                              preferences: Preferences) -> NotificationDecision {
        guard event.kind == .message else { return .suppress(.notAMessage) }
        if preferences.recordOnlyNeverAlert { return .suppress(.globallySilenced) }
        if settings.muted { return .suppress(.topicMuted) }

        let priority = event.resolvedPriority
        guard priority.rawValue >= settings.minAlertPriority else {
            return .suppress(.belowTopicThreshold)
        }

        let actions = presentableActions(from: event.actions ?? [])

        return .present(NotificationRequest(
            identifier: "\(serverID.uuidString)/\(event.topic)/\(event.id)",
            threadIdentifier: "\(serverID.uuidString)/\(event.topic)",
            // A message with no title still needs one; the topic is the most
            // useful thing the user could see there.
            title: event.title ?? event.topic,
            body: event.message ?? "",
            interruption: interruption(for: priority),
            playsSound: priority.rawValue >= NtfyPriority.default.rawValue,
            categoryIdentifier: actions.isEmpty ? nil : categoryIdentifier(for: actions),
            actions: actions,
            clickURL: event.click.flatMap(URL.init(string:)),
            attachmentURL: event.attachment.flatMap { URL(string: $0.url) }))
    }

    private static func interruption(for priority: NtfyPriority) -> NotificationInterruption {
        switch priority {
        case .min, .low: .passive
        case .default: .active
        case .high, .max: .timeSensitive
        }
    }

    private static func presentableActions(from actions: [NtfyAction]) -> [PresentableAction] {
        actions.prefix(maxActions).compactMap { action in
            switch action.kind {
            case .view:
                guard let raw = action.url, let url = URL(string: raw) else { return nil }
                return PresentableAction(id: action.id, title: action.label, kind: .view(url: url))
            case .copy:
                guard let value = action.value else { return nil }
                return PresentableAction(id: action.id, title: action.label, kind: .copy(value: value))
            case .http:
                guard let raw = action.url, let url = URL(string: raw) else { return nil }
                return PresentableAction(
                    id: action.id, title: action.label,
                    kind: .http(url: url, method: action.method ?? "POST",
                                headers: action.headers ?? [:], body: action.body))
            case .broadcast, nil:
                // Android-only, or a kind this version does not know. Dropping
                // the button is better than showing an inert one.
                return nil
            }
        }
    }

    /// Stable for a given action shape, different for a different one. macOS
    /// caches categories by identifier, so a collision would show the wrong
    /// buttons on a later notification.
    private static func categoryIdentifier(for actions: [PresentableAction]) -> String {
        let shape = actions.map { action -> String in
            switch action.kind {
            case .view: "view:\(action.id):\(action.title)"
            case .copy: "copy:\(action.id):\(action.title)"
            case .http: "http:\(action.id):\(action.title)"
            }
        }.joined(separator: "|")
        return "ntfy.actions.\(shape.hashValue.magnitude)"
    }
}
```

**Note:** `NtfyAction` currently exposes `action: String` with a computed `kind: Kind?` (changed in Stage 3 for forward compatibility). Use `action.kind`, and treat `nil` as unknown-and-dropped, exactly as the `case .broadcast, nil` arm above does. **`hashValue` is not stable across process launches** — check whether that matters for category identifiers, which macOS caches per launch, and say what you concluded in your report. If it does matter, use a stable hash you compute yourself.

- [ ] **Step 5: Run and verify, with the mandatory mutations**

```bash
swift test --filter NotificationDecisionTests 2>&1 | tail -30
swift test 2>&1 | tail -3
```

Four tests assert suppression — `aMutedTopicIsSuppressed`, `aMessageBelowTheTopicThresholdIsSuppressed`, `theGlobalRecordOnlyToggleSuppressesEverything`, `keepaliveAndOpenNeverNotify`. **Mutate each in turn** by deleting the guard that produces it, confirm the corresponding test FAILS, restore. Report all eight results.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: pure notification decision covering every suppression rule"
```

---

### Task 5: The app target presents notifications

**Files:**
- Create: `Sources/NtfyMe/NotificationPresenter.swift`, `Sources/NtfyMe/NotificationActionHandler.swift`
- Modify: `Sources/NtfyMe/AppDelegate.swift`

**Interfaces:**
- Consumes: `NotificationRequest`, `PresentableAction`, `NotificationInterruption`.
- Produces:
  - `final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate` with `requestAuthorization() async -> Bool`, `present(_ request: NotificationRequest) async`, `registerCategory(for:)`.
  - `enum NotificationActionHandler` with `perform(_ action: PresentableAction) async`, `openClickURL(_ url: URL)`.

This code cannot be unit tested — it talks to `UNUserNotificationCenter`, which needs a real bundle. That is exactly why Task 4 exists. Keep this file thin: translation only, no rules.

- [ ] **Step 1: Write the presenter**

`Sources/NtfyMe/NotificationPresenter.swift`:

```swift
import Foundation
import UserNotifications
import NtfyKit

/// Translates a `NotificationRequest` into the system's notification API.
///
/// Deliberately contains no policy: every rule about whether and how to notify
/// lives in `NotificationDecision`, where it is unit tested. This file is the
/// untestable edge, so it stays as thin as possible.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var registeredCategories: Set<String> = []

    /// Requested after an explanatory pane, never as a cold prompt (spec §6).
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            let ns = error as NSError
            Log.app.error("notification authorization failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return false
        }
    }

    func present(_ request: NotificationRequest) async {
        if let categoryID = request.categoryIdentifier {
            registerCategoryIfNeeded(categoryID, actions: request.actions)
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadIdentifier
        content.interruptionLevel = level(for: request.interruption)
        if request.playsSound { content.sound = .default }
        if let categoryID = request.categoryIdentifier { content.categoryIdentifier = categoryID }
        content.userInfo = ["clickURL": request.clickURL?.absoluteString ?? ""]

        do {
            try await center.add(UNNotificationRequest(
                identifier: request.identifier, content: content, trigger: nil))
        } catch {
            let ns = error as NSError
            Log.app.error("notification delivery failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }

    private func level(for interruption: NotificationInterruption) -> UNNotificationInterruptionLevel {
        switch interruption {
        case .passive: .passive
        case .active: .active
        // Requires an entitlement that cannot be signed locally, so this
        // degrades to .active in a development build (spec §11).
        case .timeSensitive: .timeSensitive
        }
    }

    private func registerCategoryIfNeeded(_ id: String, actions: [PresentableAction]) {
        guard !registeredCategories.contains(id) else { return }
        let unActions = actions.map {
            UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground])
        }
        center.setNotificationCategories(
            center.notificationCategories.union([
                UNNotificationCategory(identifier: id, actions: unActions,
                                       intentIdentifiers: [], options: [])
            ]))
        registeredCategories.insert(id)
    }
}
```

**Note:** `center.notificationCategories` is `async` on macOS; adjust the registration to await it, or keep a local set as the source of truth and call `setNotificationCategories` with the accumulated set. Say which you chose and why.

- [ ] **Step 2: Write the action handler**

`Sources/NtfyMe/NotificationActionHandler.swift`:

```swift
import AppKit
import Foundation
import NtfyKit

/// Performs the action behind a notification button.
enum NotificationActionHandler {
    static func perform(_ action: PresentableAction) async {
        switch action.kind {
        case .view(let url):
            NSWorkspace.shared.open(url)

        case .copy(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)

        case .http(let url, let method, let headers, let body):
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            if let body { request.httpBody = Data(body.utf8) }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Reported, not swallowed: a user pressing a button deserves to
                // know it failed. The URL is never logged — it is server-supplied.
                Log.app.info("notification http action returned \(status, privacy: .public)")
            } catch {
                let ns = error as NSError
                Log.app.error("notification http action failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            }
        }
    }

    static func openClickURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 3: Add the `app` log category**

In `Sources/NtfyKit/Log.swift`, add alongside the existing categories:

```swift
    /// App-target concerns: notifications, login item, scheduling.
    public static let app = Logger(subsystem: subsystem, category: "app")
```

and extend that file's doc comment to describe the new sites: they interpolate a fixed literal plus, at most, an HTTP status code or an `NSError` domain and code. **A notification's title and body are shown to the user but must never be logged**, and neither must an action's URL — it is server-supplied.

- [ ] **Step 4: Build and verify nothing regressed**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -3
```

Expected: builds clean, all prior tests still pass. There are no new tests here by design — say so in your report rather than inventing one that asserts nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: present notifications and perform their actions"
```

---

### Task 6: Login item and retention scheduling

**Files:**
- Create: `Sources/NtfyMe/LoginItem.swift`, `Sources/NtfyMe/RetentionScheduler.swift`

**Interfaces:**
- Consumes: `Preferences`, `PreferencesStore`, `MessageStore`, `RetentionPolicy`.
- Produces:
  - `enum LoginItem` with `static var isEnabled: Bool`, `static func setEnabled(_:) throws`.
  - `actor RetentionScheduler` with `init(store:policy:)`, `func start()`, `func stop()`, `func pruneNow() async`.

- [ ] **Step 1: Write the login item wrapper**

```swift
import Foundation
import ServiceManagement
import NtfyKit

/// Launch-at-login via `SMAppService` (spec §7's General settings).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 2: Write the scheduler**

```swift
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

    private func attachmentsDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appending(path: "dev.aloi.NtfyMe/Attachments")
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -3
```

Expected: builds clean, all prior tests pass. `SMAppService` is not unit testable without an installed, signed app — say so rather than writing a test that asserts nothing.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: launch-at-login wrapper and daily retention scheduling"
```

---

### Task 7: Wire the graph, and make the app actually notify

The task where it becomes a working app. Everything before this is parts.

**Files:**
- Modify: `Sources/NtfyMe/AppDelegate.swift`
- Create: `Sources/NtfyMe/AppGraph.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `@MainActor final class AppGraph` with `init()`, `func start() async`, `func stop() async`.

- [ ] **Step 1: Write the graph**

`Sources/NtfyMe/AppGraph.swift`:

```swift
import AppKit
import Foundation
import SwiftData
import NtfyKit

/// Builds and owns the object graph: store, coordinator, notifications,
/// retention. One instance, created by the app delegate.
@MainActor
final class AppGraph {
    private let container: ModelContainer
    private let store: MessageStore
    private let preferences: PreferencesStore
    private let presenter = NotificationPresenter()
    private var coordinator: ConnectionCoordinator?
    private var scheduler: RetentionScheduler?
    private var notifyTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init() throws {
        // On-disk, unlike every test in this project — this is the real store.
        container = try ModelContainer(for: Server.self, Subscription.self,
                                       Message.self, Attachment.self)
        store = MessageStore(modelContainer: container)
        preferences = PreferencesStore()
    }

    func start() async {
        let prefs = preferences.load()

        let coordinator = ConnectionCoordinator(
            store: store,
            keychain: KeychainStore(),
            client: NtfyStreamClient(),
            pathMonitor: SystemPathMonitor(),
            ingest: Ingest(store: store))
        self.coordinator = coordinator
        await coordinator.start()

        let scheduler = RetentionScheduler(store: store, policy: prefs.retention)
        self.scheduler = scheduler
        await scheduler.start()

        // Wake from sleep: reconnect immediately rather than waiting out
        // backoff. This is the AppKit half the coordinator cannot own.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { await coordinator.reconnectAll() }
            }
    }

    func stop() async {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        notifyTask?.cancel()
        await scheduler?.stop()
        await coordinator?.stop()
    }

    func requestNotificationAuthorization() async -> Bool {
        await presenter.requestAuthorization()
    }
}
```

**Note for the implementer:** this graph starts the coordinator and the scheduler but **never presents a notification** — nothing consumes messages and calls `NotificationDecision.decide`. That is the missing piece and it is your job to add it. The shape that fits what exists: the coordinator should expose the events it is already pumping, or `Ingest` should offer a hook for messages it successfully stored. **Prefer notifying on messages that were stored**, not merely received — the same "persisted, not received" principle Stage 3 established for the resume point, and for the same reason: a notification for a message that is not in the archive is a message the user cannot go back and find.

Describe the shape you chose and why in your report. If you conclude the plan's structure is wrong for this, say so rather than forcing it.

- [ ] **Step 1b: Add `alertSettings` to the store, with its test**

Per-topic settings live on the `Subscription` row and the decision needs them.
Write the test first, in `Tests/NtfyKitTests/MessageStoreTests.swift`:

```swift
@Test func alertSettingsComeFromTheSubscriptionRow() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    let server = Server(id: id, name: "Alpha", baseURLString: "https://a.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server,
                                muted: true, minAlertPriority: 4))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let settings = try await store.alertSettings(forServer: id, topic: "alerts")
    #expect(settings.muted == true)
    #expect(settings.minAlertPriority == 4)
}

/// A message for a topic with no subscription row must not be silently
/// suppressed — defaulting to muted would hide messages the user can see in
/// the archive but was never told about.
@Test func alertSettingsForAnUnknownTopicDefaultToAlerting() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    context.insert(Server(id: id, name: "Alpha", baseURLString: "https://a.example.com"))
    try context.save()

    let settings = try await MessageStore(modelContainer: container)
        .alertSettings(forServer: id, topic: "nope")
    #expect(settings.muted == false)
    #expect(settings.minAlertPriority == 1)
}
```

Then append to `MessageStore`:

```swift
    /// Per-topic alert settings for the decision. An absent subscription row
    /// defaults to alerting: suppressing by default would hide messages the
    /// user can find in the archive but was never told about.
    public func alertSettings(forServer serverID: UUID,
                              topic: String) throws -> TopicAlertSettings {
        guard let sub = try subscriptions(forServer: serverID)
            .first(where: { $0.topic == topic }) else {
            return TopicAlertSettings(muted: false, minAlertPriority: 1)
        }
        return TopicAlertSettings(muted: sub.muted, minAlertPriority: sub.minAlertPriority)
    }
```

`alertSettingsForAnUnknownTopicDefaultToAlerting` asserts `false` and a floor
value. **Mutate:** make the fallback `muted: true`; confirm it FAILS; restore.

- [ ] **Step 2: Wire the delegate**

Modify `AppDelegate.applicationDidFinishLaunching` to construct `AppGraph`, start it, and keep it alive for the app's lifetime; and add `applicationWillTerminate` to stop it. Keep the existing status item and Quit menu untouched.

- [ ] **Step 3: Build, run, and verify by hand**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -3
Scripts/build-app.sh && open build/NtfyMe.app
```

Then, with the app running, publish to a scratch topic you add to the store and confirm a notification appears. **This is the first end-to-end verification in the project** — describe exactly what you did and what you observed, including whether the notification permission prompt appeared. If you cannot complete it (no configured server, no permission), say precisely where you stopped.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: wire the app graph so stored messages raise notifications"
```

---

## Definition of Done for Stage 4a

- Servers load from the store and connect on launch, each seeded with its persisted watermarks and `caughtUpTo` — closing Stage 3's open loop.
- A network path returning, or waking from sleep, reconnects immediately rather than waiting out backoff.
- A stored message raises a native notification unless muted, below its topic's threshold, or globally silenced.
- Actions appear as buttons; `broadcast` never does.
- Retention runs at launch and daily.
- `NtfyKit` still imports no UI framework and no `UserNotifications`.
- Every negative assertion in this plan has been run against a deliberately broken build.
- Full suite green, zero warnings, CI green.

## Known partial coverage of spec §6

§6 says authorization is "requested after a short explanatory onboarding pane,
never as a cold prompt on first launch". This plan builds
`requestAuthorization()` but **not the pane** — that is UI and belongs to
Plan 4. So do not call `requestAuthorization()` from `start()`: leave it for
Plan 4 to call from the pane. Task 7's manual verification may need to grant
permission by hand, which is expected.

## What this plan deliberately does not build

- **Plan 4 (Stage 4b):** the menu bar popover, History window, Settings UI, onboarding pane, attachment downloading.
- **Plan 5 (Stage 5):** compose sheet, attachment upload, Developer ID signing and notarization.

Carried forward from Stage 3, still open:
- `record()` advances in-memory watermarks on receipt, so a buffer-overflow drop can let an in-process reconnect skip. Narrow and self-limiting; needs `record()` moved behind the persisted-not-received rule.
- Hoisting `Ingest`'s persist above its `do`/`catch` would fail no test; closing that needs a `MessageWriting` seam.
- `MessageStore.prune` counts per topic in memory; `insert` does an O(n) per-key existence fetch.
- Adding a topic must reset `Server.caughtUpTo`, or a message published between the backfill poll and the stream rebuild is on neither stream.
- Deleting a `Server` orphans its `Message` rows and attachment files.
- `Server.authKindRaw` is coupled to `AuthCredential`'s case name by string.
