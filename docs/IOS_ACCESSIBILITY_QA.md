# iOS simulator accessibility QA — 5 September 2026

**Final verification status: passed for all six checks in each of the four
device/appearance configurations (24 case executions), including targeted
reruns after correcting the test harness.** The full visual accessibility audit
retains the qualified findings described below.

This follow-up exercises the existing iOS app after the
[repository audit](REPOSITORY_AUDIT_FOLLOWUP.md). Tests use isolated demo speaker
records and do not issue commands to physical speakers. No release or version
metadata changes are part of this work.

## Final matrix

| Simulator | Appearance | Final six-test result | Result bundle |
| --- | --- | --- | --- |
| iPhone 17 Pro | Light | 6/6 passed | `/tmp/ampestra-qa-iphone-light.xcresult`; `/tmp/ampestra-qa-iphone-light-confirmed.xcresult` |
| iPhone 17 Pro | Dark | 6/6 passed | `/tmp/ampestra-qa-iphone-dark.xcresult` |
| iPad mini (A17 Pro) | Light | 6/6 passed | `/tmp/ampestra-qa-ipad-light.xcresult`; `/tmp/ampestra-qa-ipad-light-confirmed.xcresult` |
| iPad mini (A17 Pro) | Dark | 6/6 passed | `/tmp/ampestra-qa-ipad-dark.xcresult`; `/tmp/ampestra-qa-ipad-dark-reduced.xcresult` |

Runs used iOS Simulator 27.0 and Xcode 27 beta (`27A5252f`). Repeating one method on another device or
appearance is a separate execution, not a new distinct test.

## Coverage

[AccessibilityMatrixTests.swift](../iOS/AmpestraMobileIntentTests/AccessibilityMatrixTests.swift)
contains six reusable UI tests. Screenshot attachments identify the screen and
Dynamic Type category; their result bundle identifies the device and appearance.

| Test | Checks |
| --- | --- |
| Remote controls across Dynamic Type sizes | Standard Large, standard XXXL, accessibility Medium, and accessibility XXXL; volume down, mute, restore, volume up, pause/play, and selection of TV as the source. Checks the slider's announced percentage and that the main reading never becomes smaller at each successive text category. |
| Settings and connection | Standard Large and accessibility XXXL; Settings, preset application, Siri instructions, Settings-to-connection sheet transition, saved-speaker availability label, manual-address field, disabled empty-address submission, and dismissal back to the remote. |
| Largest text in landscape | Standby guidance and reachable Power on action, absence of active volume controls during standby, then power-on and volume adjustment in landscape. Restores portrait orientation. |
| Maximum volume at largest text | Moves the slider to its upper endpoint and uses Volume up to settle any synthetic-drag rounding, verifies its accessible value, checks that the three-digit reading fits within the window, and captures the result. |
| System accessibility semantics | Launches without a text-size override and runs strict element-detection, hit-region, sufficient-description, and trait checks on the remote and Settings. |
| Reduce Motion and Reduce Transparency | Uses the simulator's Settings app to enable both preferences, then exercises volume and mute/restore at accessibility XXXL, captures the rendering, and performs the same strict semantic checks. Restores the preferences to their incoming values. |

The system-switch harness taps the actual trailing control and verifies its
value, including restoration. UIKit preference values in the background test
runner were not used as evidence of the foreground app’s state. A synthetic
slider drag occasionally ended below 100% on iPad; the test now uses Volume up
to verify the endpoint deterministically.

The four-size interaction matrix intentionally uses an app launch argument for
repeatable text sizing. The dedicated system audit follows the simulator's
actual text-size preference. This avoids pinning the app to one category while
the audit attempts its own changes.

## Findings and fixes

| Finding | Change |
| --- | --- |
| The large numeric volume reading used fixed font sizes; switching to compact accessibility layout could make it smaller. | The reading now uses scaled metrics, uses the regular-size baseline throughout accessibility categories, and bounds the largest reading to 160 points. A horizontal fit fallback limits it to 128 points when needed so three-digit values remain usable on narrow screens. |
| Secondary text had insufficient light-mode contrast on cards and Settings backgrounds. | Added an opaque adaptive secondary-text color and applied it to the remote, Settings values, section headings, footers, and Siri explanations. Increased Contrast uses the system label color. |
| Light-mode accent and destructive text needed stronger contrast. | Darkened the light accent and the Settings Forget speaker label. The destructive action retains its destructive role; dark mode retains an appropriate red. |
| Playback metadata was limited to a single line outside accessibility categories. | Metadata now wraps at standard sizes as well, so larger standard text does not depend on truncation. |

These changes address readability and existing controls. They do not add new
speaker capabilities. Redundant `internal(set)` modifiers and an unused view
environment property were also removed; the final build has no Swift compiler
warnings, and Xcode project regeneration and `git diff --check` pass.

## Completed investigation and audit qualifications

The first light-mode iPhone run completed all functional assertions in the
original three-method interaction suite. Its XCTest result was **failed**
because the unfiltered accessibility audit reported visual findings. The
attached full-screen images were inspected alongside the individual element
crops; this run is not counted as a clean accessibility pass.

After the contrast and text changes, a dedicated unfiltered system audit was
also run without the launch-time text-size override. It still recorded **19
findings: 3 contrast, 11 partially unsupported Dynamic Type, and 5 text-clipping
findings**. Removing the launch override therefore did not eliminate the visual
audit findings.

The findings were investigated as follows:

- **Contrast:** the residual reports identified glass controls such as Mute,
  Power, and Done. Screenshot colors were converted from their embedded color
  space to sRGB before computing relative luminance. Measured interior text/fill
  ratios were **6.36:1 for Mute**, **5.62–5.82:1 for Power**, and
  **5.74–5.95:1 for Done**. These measurements support the inspected renderings;
  they are not an exhaustive contrast certification for every background,
  animation frame, or display configuration.
- **Dynamic Type:** full-screen images show native Settings labels and values
  growing and wrapping between standard Large and accessibility XXXL, despite
  audit reports of partial support for those elements. Some system controls and
  the main volume reading have bounded visual sizes. The volume bound is a
  deliberate fit constraint, with its full value still exposed accessibly.
- **Clipping:** several cropped accessibility-element images disagree with the
  full rendered screen. For example, the crop for the wrapped Change speaker
  label excludes the left edge of its second line, while that line is intact in
  the full-screen image. Reconnect is also reported despite its complete text
  appearing in both standard and largest-text screenshots. Screen content below
  the viewport was checked by scrolling to its controls.

Consequently, the automated regression method keeps **element detection,
hit-region, description, and trait audits strict**, with no issue filters for
those categories. Contrast, Dynamic Type, and clipping results from the full
visual audit are documented and reviewed with screenshots instead of being
treated as reliable binary regressions in this simulator/toolchain. **This
report does not claim that the unfiltered full accessibility audit passed.**

## Evidence

The following local artifacts are temporary simulator QA output rather than
checked-in project assets:

- Initial iPhone light run:
  `/tmp/ampestra-accessibility-iphone-light.xcresult` and
  `/tmp/ampestra-accessibility-iphone-light-attachments/manifest.json`.
- Unfiltered audit without a text-size override:
  `/tmp/ampestra-accessibility-system-light.xcresult` and
  `/tmp/ampestra-accessibility-system-light-attachments/manifest.json`.
- Screenshot contrast calculation:
  `/tmp/ampestra-measure-contrast.swift`. The script reads the embedded image
  color space, converts sampled colors to sRGB, and reports their luminance and
  contrast ratios. Reported ratios compare solid interior text/fill colors,
  rather than antialiased edge pixels.
- A final screenshot comparison exposed a remaining XXXL-to-accessibility font
  transition. The strengthened monotonic-size and 100% checks are checked on both
  form factors; both focused runs passed. Evidence is in
  `/tmp/ampestra-qa-iphone-scaling.xcresult` and
  `/tmp/ampestra-qa-ipad-scaling.xcresult`.
- Final result bundles are listed in the matrix above. The main light-mode
  bundles and iPad dark bundle retain the original harness failures; the
  accompanying confirmed/reduced bundles contain their passing targeted reruns.
- Final live system-preference screenshots are in
  `tmp-screenshots/accessibility-qa/final/`: five sizes (Small, Large, XXXL,
  accessibility Medium and accessibility XXXL) in each appearance on each device,
  plus increased-contrast captures at the largest size.
- Largest-text Settings, connection, presets, Siri help, source selection and
  landscape controls were also reviewed from XCTest attachments. Screen-level
  screenshots replaced app-level captures to avoid an iPad rotation capture
  artifact (portrait bounds and a black band).

The initial Settings screenshots
`5A0952E7-984F-4D45-9677-10AD0942D918.png` (standard Large) and
`10522ABC-CC4C-4F6B-A880-2A473CCE6A96.png` (accessibility XXXL) are in the initial
attachment directory. Its manifest maps other attachment filenames to their
human-readable screen names and test methods.

## Remaining limits

Simulator interactions validate layout, exposed accessibility properties, and
demo-state transitions. They do not validate physical speaker delivery,
hardware volume buttons, actual audio, real Siri execution, or device-only
permission behavior; use the [hardware checklist](IOS_HARDWARE_TESTING.md) and
[Siri checklist](IOS_SIRI_TESTING.md) for those checks.

VoiceOver auditory output and focus-navigation experience, Switch Control,
external assistive devices, and every intermediate text size were not manually
validated. This work does not claim exhaustive accessibility certification or
measured performance/battery improvements. Other iOS versions and iPad split
window sizes were not exercised in this pass.
