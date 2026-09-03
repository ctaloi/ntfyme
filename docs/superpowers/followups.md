# Known gaps and follow-ups

Findings from the pre-merge whole-branch review that were deliberately **not**
fixed before merging, with the reasoning. Recorded here rather than in a
scratch file so they survive the session that found them.

Each was ranked "carry" by the reviewer that found it, on the grounds that it
is either missing work rather than broken work, or has a workaround visible to
the user.

## App layer

**History window shows stale data on re-open, and never updates while open.**
`HistoryWindowController.show()` only calls `makeKeyAndOrderFront` for an
existing window; `loadSidebar`/`refreshMessages` run only on first creation.
Nothing else feeds that view model — `AppDelegate`'s refresh timer updates the
graph states and the menu bar, and `graph.onStoredBatch` updates only the menu
bar. Close History, receive ten messages, reopen: the ten are absent until the
user touches a filter. Fix: call both loads on every `show()`, and fan
`onStoredBatch` out to the History controller as well.
*Carried because the workaround — change a filter — is visible to the user.*

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
