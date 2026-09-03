# Known gaps and follow-ups

Findings from the pre-merge whole-branch review that were deliberately **not**
fixed before merging, with the reasoning. Recorded here rather than in a
scratch file so they survive the session that found them.

Each was ranked "carry" by the reviewer that found it, on the grounds that it
is either missing work rather than broken work, or has a workaround visible to
the user.

## App layer

**The Quick Look preview panel has never been opened.** Attachment download is
verified end to end — a real message published to a live topic produced a file
on disk with its generated filename recorded in the store — and the detail
pane's preview button is wired against it. But nobody has clicked that button
and watched a panel appear. Snapshot renders cannot show it, and driving it
through the accessibility API proved unreliable. Verify interactively before
claiming it works.


**⌘, does not open Settings.** Settings is now hosted by
`SettingsWindowController` rather than the SwiftUI `Settings` scene, because
that scene could not be opened from a menu-bar accessory at all (see that
file's doc comment). The scene is still declared, so the app compiles and has
a scene, but nothing routes the standard shortcut to the real window —
verified in the running app: ⌘, opens nothing. Route the scene, or install a
menu item, so the platform-standard shortcut works once the app is `.regular`.


**Seed ntfy.sh as a default server on first run.** A new user currently
arrives at an empty Servers tab and has to know that `https://ntfy.sh` is the
public instance before anything can happen. Pre-seeding it — with no topics,
so nothing connects until the user adds one — removes that step without
subscribing them to anything. Requested during the first live walkthrough.


**An open History message list does not show messages that arrive while it
is open.** Mostly fixed: `HistoryWindowController.show()` now reloads on every
call rather than only on window creation, and `StoreChangeBroadcast` fans every
store write — configuration changes from Settings and stored message batches
alike — out to the sidebar and the status item. What remains is the message
list itself. It is deliberately *not* on the broadcast: `refreshMessages()`
re-fetches from offset 0, so refreshing it on every batch would reset
pagination to the first page under a user who had loaded more, which is a worse
trade on every write than the staleness it fixes. A real fix merges a stored
batch into the current page rather than re-fetching it, which is more than a
wiring change. Workaround: any scope, filter, or window reopen reloads it.

Two bugs came out of the pattern this replaced — a mute written in Settings not
reaching the sidebar, then a topic *added* in Settings not appearing there at
all — and the second one shipped days after the first was fixed, because the
first fix was wired to one store method rather than to the idea of a write. If
a surface goes stale again, the fix is one `storeChanges.observe` in
`AppDelegate` or one `await onStoreChanged()` in the writer, not a new closure
between the two.

**Concurrent History searches can land out of order.** `HistoryViewModel`'s
`scope.didSet`, `refreshMessages`, and the debounced text path each spawn an
independent `store.search` with nothing sequencing them or discarding a
superseded result, and `isLoading`'s `defer` clears on the *first* to finish.
Type a tag (the slower Swift-side filter path), then click a different topic:
the tag query can land last and display its rows under the new topic's title.
Fix: a generation counter captured before the `await` and compared after.
*Carried because it needs a 300ms debounce to be beaten by a slower query.*

**A notification's action identifiers come from the message.**
`NotificationPresenter` uses `NtfyAction.id` verbatim, and that value is
decoded from the payload rather than generated. Duplicate or empty ids within
one message produce a malformed category and ambiguous matching in
`activation(forActionIdentifier:userInfo:)`. Fix: index-based identifiers
mapped back through the encoded payload.

**Notification activation does not scroll to the message.** Spec §6 says
clicking a notification without a `click` URL opens History *scrolled to that
message*. It opens the window; the message key is deliberately unused because
`HistoryViewModel` exposes no selection API. Tracked as a spec gap.

**The onboarding denial message is never visible.** `OnboardingView` sets
`deniedMessage` and then `onFinish()` closes the window immediately. Either
drop the message or do not auto-finish on denial.

## Tests

**The `NavigationSplitView` sidebar gap is documented but not pinned.** The
sidebar does not draw through the offscreen capture harness, so the composite
History renders pass with a third of the surface empty. This is disclosed at
length in a comment but, unlike the `.alert` gap, nothing asserts it — so
nothing will tell us if the sidebar starts working, and nothing will tell us if
the rest of the composite regresses toward it. Fix: mark it `withKnownIssue`
the way the alert gap is, or drop the composite renders in favour of the
per-column ones that do draw.

**The save-failure harness's thrown-error assertion is too broad.**
`#expect(throws: (any Error).self)` would accept an error other than the one
the test induces. It also lacks the mutation note its sibling tests carry.
