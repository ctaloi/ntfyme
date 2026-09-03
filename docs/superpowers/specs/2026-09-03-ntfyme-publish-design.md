# Publishing messages from NtfyMe

Design, approved 2026-09-03. Written before implementation; the plan that
follows it is a separate document.

NtfyMe reads. Every path in it runs one direction — `ServerConnection` →
`Ingest` → `MessageStore` → notifications — and there is no code anywhere in
the project that sends anything to a server. `NtfyEndpoint.request` hardcodes
`httpMethod = "GET"`. This adds the other direction.

## Scope

**In:** a Compose window, opened from the main window and ⌘N, that sends one
message to one topic on one configured server, carrying the fields the
receive side already displays: title, body, priority, tags.

**Out, deliberately:** click URLs, action buttons, file attachments,
scheduled delivery, and the icon field. Each is a real part of ntfy's publish
API and each is a separate piece of work — action buttons need their own
editor, attachments need upload handling and per-server size policy. The
receive side renders click URLs and actions today, so publishing them is a
natural second pass, not a gap this design is unaware of.

**Also out:** publishing from the menu bar popover. The popover dismisses on
focus loss, which fights a multi-field form. The menu bar gets a "New
Message…" item that opens the Compose window, not a form of its own.

## The request

`POST` to the server's base URL with a JSON body:

```json
{"topic": "alerts", "title": "…", "message": "…", "priority": 4, "tags": ["warning"]}
```

Chosen over `POST /{topic}` with `X-Title`/`X-Priority`/`X-Tags` headers.
Both are supported by ntfy and the header form has marginally broader
compatibility with odd proxies, but a non-ASCII title has to be percent- or
RFC 2047-encoded to survive an HTTP header, and that is the kind of detail
that produces a mojibake bug weeks later in a field nobody tested with an
umlaut. The JSON body is also the same shape `NtfyEvent` already decodes, so
the two directions stay symmetric.

Omitted fields are omitted from the body rather than sent empty: ntfy treats
an empty `title` as a title and an empty `tags` array as no tags, but not
sending them at all is unambiguous in both cases.

## Components

### `NtfyEndpoint.publishRequest(_:)` — NtfyKit

The publish request is built here, not in a new type, because this is where
topic validation (`validate`, ntfy's own `[-_A-Za-z0-9]{1,64}` rule) and
credential application (`credential.authorizationHeader`) already live, and
both apply unchanged to a publish. A second type would either duplicate them
or reach around them.

It gets its own builder rather than a `method:` parameter on the existing
private `request(path:query:)`: that one appends `/json` to the path, which a
publish must not have, and threading two behaviours through one function to
save four lines is how that function stops being readable.

### `MessageDraft` — NtfyKit

```swift
public struct MessageDraft: Sendable, Equatable {
    public var serverID: UUID
    public var topic: String
    public var title: String?
    public var body: String
    public var priority: NtfyPriority
    public var tags: [String]
}
```

A plain value. `NtfyPriority` rather than `Int`, so an out-of-range priority
is unrepresentable rather than validated. Encoding lives in `NtfyPublisher`,
not in a `Codable` conformance on this type — the wire format is the
publisher's business, and this struct is also what the Compose UI binds to.

### `NtfyPublisher` — NtfyKit

An actor holding a `URLSession`, with one method:

```swift
public func publish(_ draft: MessageDraft, to baseURL: URL,
                    credential: AuthCredential) async throws
```

Takes the URL and credential rather than resolving them, for the same reason
`ServerConnection` does: the Keychain lookup belongs to the caller that
already owns server records, and a publisher that reads the Keychain cannot
be tested without one.

Status codes map to a typed error:

| Status | Case | Shown as |
|---|---|---|
| 200 | success | — |
| 401, 403 | `.notAuthorized` | "Not authorized to publish to this topic." |
| 404 | `.topicRejected` | "The server rejected that topic." |
| 413 | `.tooLarge` | "That message is too large for this server." |
| 429 | `.rateLimited` | "The server is rate-limiting; try again shortly." |
| other | `.unexpectedStatus(Int)` | The code alone. |

No response body is ever surfaced, and no `localizedDescription` reaches a
log line — `Log.swift`'s rule is a literal plus an `NSError`'s
`domain`/`code`, because a server URL names a host and spec §9 treats that as
sensitive. 401 and 403 collapse into one case on purpose: ntfy returns either
depending on configuration, and the user's next action ("check the
credential") is identical.

### `ComposeModel` — app target

Follows `SettingsModel`'s shape exactly: `@MainActor @Observable`, holding a
`MessageDraft`, with collaborators injected as closures so the whole thing is
testable with no AppKit and no network.

```swift
init(store: MessageStore, keychain: KeychainStore,
     publish: @escaping @Sendable (MessageDraft, URL, AuthCredential) async throws -> Void)
```

State: the draft, `servers`/`topics` loaded from the store for the pickers,
`isSending`, and one `errorMessage` — the same single error channel every
`SettingsModel` mutator writes to, for the same reason (spec §10: no silent
failures).

`send()` resolves the credential from the Keychain, calls `publish`, and on
success clears the draft's title, body and tags while **keeping** the
selected server and topic — sending two messages to the same topic is the
common case, and re-picking the destination each time is friction with no
purpose.

### `ComposeWindowController` — app target

Sibling to `HistoryWindowController` and `SettingsWindowController`, same
shape: owns its `NSWindow`, exposes `show()`. Opened from ⌘N via the same
`CommandGroup` route in `NtfyMeApp` that reaches `AppDelegate.openSettings()`
for ⌘, — the one path that is known to work from this app's window setup.

Not a sheet on the History window: a message being composed should survive
closing that window, and the app deliberately outlives all its windows.

## Fields and validation

Server is a picker over `store.servers()`, required, defaulting to the only
server when there is exactly one.

Topic is a combo box: pick a subscribed topic or type any name. Publishing
does not require a subscription, and restricting the field to subscriptions
would invent a rule ntfy does not have. Validated with `NtfyEndpoint`'s
existing topic rule before the request is built, so an invalid topic is a
field-level error rather than a 404 from the server.

Body is required and is the only required field — ntfy accepts a message with
no title. Send is disabled until a server and a non-empty body exist.

## What happens to a sent message

Nothing local. It is not inserted into the archive.

Publishing to a topic this app is subscribed to means the server echoes the
message back down the already-open stream, where `Ingest` stores it exactly
as it stores any other. One source of truth, no optimistic row to reconcile,
and `uniqueKey` dedup means the same message cannot land twice.

The known consequence: **you get a notification for your own message.**
`NotificationDecision` has no idea the message originated here. This ships
that way on purpose rather than building suppression on spec — the fix, if it
turns out to be irritating, is cheap and already scoped: ntfy's publish
response carries the created message's `id`, so `NtfyPublisher` can return it
and `NotificationRouter` can be told to skip exactly that one. Recorded in
`followups.md` when this lands, with that note.

A message published to a topic this app is *not* subscribed to appears
nowhere, which is correct — there is nothing to display and no subscription
to display it under.

## Errors

Every failure surfaces in the Compose window, next to the Send button, and
the draft is never cleared on failure — losing a typed message to a 429 would
be worse than the 429.

Failures that are the user's to fix (invalid topic, empty body) are
field-level and pre-request. Failures that are the server's are the typed
error table above. A `URLError` — offline, DNS, TLS — surfaces as "Couldn't
reach the server", with `domain`/`code` logged and nothing else.

## Testing

`MockNtfyServer` (`Tests/NtfyKitTests/Support/`) is a real local socket
server with `setResponse(status:body:)`, so the entire publish path is
testable offline:

- The request itself: method, URL, `Authorization` header presence and
  absence, and the exact JSON body for a full draft and a minimal one.
  Requires extending the mock to record request bodies; it currently records
  enough to route a response.
- Every row of the status table, including that the draft survives a failure.
- Topic validation rejecting what `NtfyEndpoint` already rejects for streams,
  pinned against the same rule rather than a copy of it.

`ComposeModel` tests use an in-memory `ModelContainer` and a stub `publish`
closure, as `SettingsModelTests` does: send succeeds, send fails and keeps
the draft, credential lookup fails, and the post-success clear keeps server
and topic.

One live verification before this is called done: send to `smoke-test` on
ntfy.sh and watch it arrive in History through the normal stream path. The
mock proves the request is shaped right; only a real server proves it is
shaped right *for ntfy*.

## Security

Publishing does not widen the trust boundary in the direction that matters —
this sends data the user typed to a server the user configured — but two
things are worth stating.

A topic name on public ntfy.sh is effectively a password (README says so at
length), and the Compose window's free-text topic field is the first place in
this app where a user types one that is not already stored. It gets the same
treatment as any other topic: validated, never logged.

The draft is held in memory only. A composed-but-unsent message is not
persisted anywhere, which also means it does not survive a quit — acceptable
for a first version, and the alternative (a draft in the store) is a data
model change this design is not making.
