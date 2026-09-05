# Repository audit — 5 September 2026

Reviewed the shared KEF client, discovery and volume policies; macOS state,
controllers and SwiftUI views; iOS remote, persistence, App Intents and widgets;
tests; build and release scripts; project configuration; and documentation.
The existing uncommitted iOS/widget work was preserved. This audit did not
change release versions, create a commit, publish a release, or contact a
physical speaker.

## Fixes applied

| Area | Finding and change |
| --- | --- |
| API parsing | Large JSON floating-point numbers could trap during conversion to `Int`. Conversion now fails safely. Volume reads reject malformed or out-of-range values instead of presenting them as zero or forwarding invalid values to controls. |
| Host validation | Leading-zero IPv4 octets passed decimal validation unchanged. Addresses are now emitted in canonical decimal notation before reaching URL parsing or resolution. |
| Network lifetime | Discarded API clients now invalidate their URL sessions. Response streams are explicitly cancelled on exit and have a total resource timeout. |
| Volume workers | Both platforms reject late results and errors from cancelled or superseded volume tasks, including network cancellation errors. The obsolete iOS volume dispatcher was replaced by the shared command path described below. |
| iOS connection state | Cancelled polling and commands could modify a newly selected speaker's state. Connection identity and command generations now guard completions, error handling and busy-state cleanup. Switching speakers clears pending control state and mute restoration. Successful connections clear the permission-denied indicator. |
| iOS slider | Polling could replace an in-progress slider preview before the user released it. Snapshot application now preserves volume during preview and pending writes. |
| Background commands | Extreme volume adjustments could overflow before clamping. Adjustments are bounded before addition. Cancelled network reads no longer become retries or Wake-on-LAN fallback. Power commands respect firmware-update, setup and unknown states. |
| macOS wake | The wake control could use the first available MAC address from another discovered speaker. It now uses only the selected/trusted target, owns a cancellable task, and reports packet-send failure. A superseded connection also cannot restart polling after its initial refresh. |
| Diagnostics | Unknown speaker status text could inject raw private information into the supposedly redacted report. Unknown states now produce only `unknown`. |
| Build checks | The shell syntax loop could hide an earlier failure when the final script passed. It now exits immediately on failure. |
| Source installation | Ad-hoc production staging now applies the same host library-validation entitlement as the existing development build path. Developer ID signing retains its existing behavior. |
| Documentation/tests | Corrected stale CI claims, expanded regression and privacy coverage, and synchronized an existing timing-sensitive test with completion of initial refresh. CI is now configured as described below. |

## Follow-up findings resolved

| Finding | Resolution and evidence |
| --- | --- |
| P1 — Concurrent commands lost volume adjustments | A shared per-speaker queue spans each read/modify/write across the remote, Siri, and host-executed widget intents. Acknowledged volume is reconciled for up to five seconds while speaker snapshots catch up. Foreground taps retain submission order, queued work is bounded/cancellable, and mute restoration is shared. Regression tests cover two concurrent services, foreground/intent overlap, absolute/relative tap order, mute restoration, cancellation, and deadlines. |
| P1 — Forget removed all saved speakers | Forget removes only the selected saved ID, repairs the default, and reloads widget/Shortcuts configuration. A two-speaker test verifies the other record survives and becomes the default. |
| P1 — Historical addresses and conflicting MACs could redirect commands | Commands use only the confirmed primary address and compare saved name/model with the snapshot. Different known MACs cannot claim an existing ID; the old record requires reconfirmation. Automatic reconnects also check identity. Writes recheck that the record still exists and its address/identity have not changed during the read. Tests cover legacy alternate addresses, conflicting MACs, changed identity, and forgetting or moving a speaker during a read. |
| P2 — Release target/notes checks | Before packaging and again before upload, release scripts verify local/remote tag targets and clean committed metadata. New releases target the captured commit; replacing explicitly authorized assets updates GitHub notes as well as the appcast. Nine isolated tests stub all Git, GitHub, and packaging operations, including failures and literal multiline notes. |
| P2 — Network work budgets | Responses have an eight-second total resource timeout and explicitly cancel abandoned streams. Background commands have a 25-second deadline, including shared-queue waiting. Discovery allows four concurrent resolutions and 64 services per scan, cancels pending work, and polls cancellation during DNS resolution. Slow-stream, deadline, discovery-flood, and cancellation tests pass. |
| P2 — Layout and automation | The remote scrolls in constrained windows, centers bounded content on iPad, and stacks volume/action controls for accessibility text. Accessibility source selection uses a scrollable sheet after a stronger iPad test exposed failed selection in the oversized native menu. A UI regression verifies landscape orientation, the largest accessibility text size, a long error, scrolling, and selecting an input. CI runs macOS checks, iPhone simulator tests, and the iPad accessibility regression; `make check-all` provides the combined local entry point. Generated-project consistency is checked in CI. |

Address consistency checks assume a trusted local network; name/model and
Bonjour MAC information are not cryptographic authentication. A renamed speaker
or legacy record without a model needs explicit reconnection. Same-MAC discovery
preserves the saved ID after an address change; without that evidence, a manual
connection at a new address may require selecting a new Shortcuts entity.

## Validation

- `make check`: passed, including warnings-as-errors compilation, **71 macOS
  tests**, **9 isolated release-script tests**, shell syntax, plist validation,
  and version consistency.
- iPhone 17 Pro / iOS 27.0: **43 behavior tests and 5 metadata/UI tests passed**.
  The strengthened landscape test also passed with an explicit orientation
  assertion and a full-screen screenshot that was visually inspected.
- iPad mini (A17 Pro) / iOS 27.0: **43 behavior tests and 5 metadata/UI tests
  passed**, including the final in-flight identity-change regression. The
  corrected accessible source picker also passed its stronger selection and
  dismissal assertions, and its full-screen result was visually inspected.
- The app, shared core, and widget extension compile. Regenerating the project
  with XcodeGen produces no changes. CI YAML parses successfully; hosted Actions
  have not run from this uncommitted working tree.
- The C launcher passed Clang static analysis with `-Wall -Wextra -Werror` and
  Xcode's iOS app/widget analysis completed during the initial audit.
- An isolated shell harness verified failure propagation and both installer
  signing branches using a stubbed signing command during the initial audit.
- `git diff --check`: passed.

There are **128 distinct passing tests** across the macOS, Python, iOS behavior,
and metadata/UI suites; simulator repetition is not counted twice. Non-fatal
Xcode messages include duplicate test-bundle rpath and metadata extraction being
skipped for targets containing no intents.

## Validation still requiring hardware or an external run

The code findings above are addressed. Physical volume buttons, audio
interruptions, Local Network permission recovery, Siri delivery, widget execution,
Wake-on-LAN, and real speaker firmware behavior still require the checks in
[IOS_HARDWARE_TESTING.md](IOS_HARDWARE_TESTING.md) and
[IOS_SIRI_TESTING.md](IOS_SIRI_TESTING.md). Simulator tests do not establish those
hardware outcomes. Signed source-app launch, signing/notarization, older macOS
versions, and an external dependency-advisory review were not exercised. No
release metadata was changed and no release was created or replaced.
