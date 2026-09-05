# Repository audit follow-up — 5 September 2026

Reviewed the working tree starting at `9ff30c7`: shared KEF networking and
policies; macOS state, input controllers and views; iOS state, hardware-volume
lifecycle, persistence, App Intents, widgets and views; tests; build scripts,
CI, dependency advisories and packaged resources. Parallel reviews were followed
by independent integration reviews and regression testing.

This is a follow-up to [the earlier audit](REPOSITORY_AUDIT.md). Changes focus on
existing behavior. App versions/build numbers were preserved, and no release,
upload or physical speaker command was performed.

## Fixes

| Area | Problem and resulting behavior |
| --- | --- |
| Updater dependency | Raised the minimum and resolved Sparkle version from 2.9.2 to 2.9.6. Upstream identifies 2.9.6 as fixing two high-severity installer path/symlink issues affecting the previously pinned version. Verified the downloaded framework reports 2.9.6. See [path validation advisory](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5) and [cache cleanup advisory](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp). |
| Volume and input transitions | Both platforms discard queued volume changes when source/power changes begin. iOS temporarily suspends volume and hardware input for those transitions, while preserving volume input during playback actions. macOS clears mute restoration across input changes and lets busy media keys fall through to the system. Failed iOS volume writes discard later queued taps. |
| Stale responses and cancellation | macOS accepts only the latest playback result for the current input. Cancelled refreshes cannot apply snapshots, probe health or record connection failures. iOS reconciles briefly lagging volume reads with confirmed commands and validates saved identity after asynchronous reads/reconciliation. |
| Reconnection and saved identity | iOS rejects polling responses from a different identity, reconnects cannot recreate forgotten records or move saved addresses backwards, and inactive speaker selections retain their MAC address. Blank names match consistently. Explicit reconfirmation preserves IDs and volume limits when unambiguous; exact MAC matches and active records take priority over old invalidated records. Missing Shortcut entities retain unavailable IDs rather than targeting a new default. |
| Shared API and discovery | Malformed/blank model responses fail without permanently caching the wrong write protocol. Empty playback metadata becomes absent metadata. Optional RAOP failure no longer marks an active HTTP search as finished; primary browser failure stops the scan, and failed permission-denial states are handled. |
| Volume values | Fixed-step control preserves 0% and 100%, including steps such as 7 and 8. macOS controls preserve off-grid ceilings without double-rounding or treating programmatic slider updates as user writes. Clamped iOS step settings now persist. |
| iOS hardware capture | Reattaching the same system-volume slider during SwiftUI updates no longer resets its recentering delay. Slider lookup stops at the first match instead of allocating all descendants. Audio interruptions are ignored when capture is not requested. |
| Connection UX | Recovery controls remain usable during automatic reconnect. iOS connection sheets dismiss only after a connection requested within that sheet, and Settings-to-connection transitions wait for actual dismissal. macOS manual tests cancel when edited/closed, show actual connection state, and preserve the saved address on disconnect. |
| Accessibility and layout | iOS speaker/playback text wraps at accessibility sizes, small controls have at least 44-point targets, volume is one VoiceOver element, sources announce selection, and remaining slider/banner animations respect Reduced Motion. macOS improves control labels, error wrapping and help for truncated text. Menu sizing now applies when content attaches or moves to a window. |
| Presets and feedback | iOS disables preset Apply in standby/offline while keeping editing available. The macOS preset editor retains its original speaker and saves only edited presets, preserving independently changed limits. Copy feedback handles repeated actions and cancellation. |
| Persistence and rendering work | Saved-speaker views and entity queries decode records once per operation instead of once per row/identifier. Unchanged audible-volume/default/preference writes are skipped. Widget reload ownership is centralized, and preset/limit edits no longer reload widget content that does not display those values. The deliberately removed widget timestamp remains removed. |
| Lifetime and dead code | Media-key event taps invalidate before their owner disappears, verify readiness and recover invalid ports. Removed redundant protocol caching, unreachable loopback validation, an unused hardware-origin parameter, a redundant widget wrapper and obsolete success-state UI. |
| Build behavior | Failed compilation no longer closes the running source/development app. Two isolated process-stub regressions cover these failure paths. The C launcher passes static analysis. |
| Privacy resource packaging | The existing privacy manifest now lives in shared resources so both the app and widget bundle include it; added the App Group UserDefaults reason alongside the existing app-local reason. Verified both built bundles. This matches [Apple's per-bundle requirement](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) and [UserDefaults reason definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype). |

## Validation

- `make check`: passed with warnings-as-errors compilation, **108 macOS/core
  tests**, **11 isolated script tests**, shell syntax checks, plist/entitlement/
  privacy-manifest validation and version consistency.
- `make ios-test SDK=27`: **89 behavior tests and 12 UI/metadata tests passed**
  on iPhone 17 Pro / iOS 27.0.
- The same final build passed all **101 tests** on iPad mini (A17 Pro) / iOS
  27.0 using `xcodebuild test-without-building`.
- **220 distinct passing tests**, including **45 added regression tests**.
  Repeating the iOS suite on another simulator is not counted as new tests.
- Visually inspected iPhone light/dark remote screenshots and captured iPhone/
  iPad accessibility layouts for landscape controls, volume presets and speaker
  selection; also inspected iPhone diagnostics and Siri help. The Siri-help test
  now sets its own text size/orientation and scrolls to lazily created content,
  fixing the failure exposed by the initial suite run.
- Xcode `analyze` passed for the iOS app/framework/widget scheme. Clang analysis
  of the C launcher with `-Wall -Wextra -Werror` reported no diagnostics.
- Verified the privacy manifest and both UserDefaults reasons in the built app
  and widget bundles. Regenerating the Xcode project produces identical content.
- `git diff --check`: passed. App release metadata remains unchanged.

Xcode's simulator logs include non-fatal App Shortcuts parameter-refresh and
debugger-version messages. The exported intent metadata tests pass; these logs
do not establish real Siri delivery, which remains a device check.

## Practical limits

Tests use controlled clients, local HTTP fixtures and simulator demo data.
Physical volume buttons, media-key interception, audio interruptions, Local
Network permission transitions, Siri delivery, widget execution on a device,
Wake-on-LAN and real KEF firmware still require the existing
[hardware checklist](IOS_HARDWARE_TESTING.md) and
[Siri checklist](IOS_SIRI_TESTING.md).

Performance improvements remove demonstrated duplicate work; this audit does
not claim measured battery, memory or latency gains. macOS menu sizing has real
NSWindow regression coverage, but older macOS versions and constrained-display
visual layouts were not exercised. Signed distribution, notarization and hosted
CI were not run. GitHub confirms the configured `xcode-27` runner is a supported
[public-preview image](https://github.blog/changelog/2026-07-16-xcode-27-runner-image-now-in-public-preview/).

## Extended iOS simulator QA

The subsequent [accessibility QA pass](IOS_ACCESSIBILITY_QA.md) exercised both
form factors in light/dark mode, Dynamic Type, increased contrast, and actual
Reduce Motion/Reduce Transparency settings. It fixed volume-number scaling and
text contrast, with six UI checks passing across four device/appearance
configurations after targeted harness reruns. See that report for evidence and
the full visual-audit qualifications.
