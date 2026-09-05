# iOS hardware test checklist

The simulator verifies compilation, lifecycle/state behavior, layout, and the
network client's request logic. These checks require a physical iPhone and KEF
speaker because the simulator does not expose real volume buttons or the local
speaker network.

## First connection

- Install with the **Ampestra iOS** scheme and allow Local Network access.
- Confirm Bonjour lists the speaker and connects.
- Forget the speaker, reconnect with its private IP, and confirm manual fallback.
- Deny Local Network access, confirm the in-app explanation and Settings link,
  then re-enable access and reconnect.

## Volume

- Tap `−`, mute/unmute, and `+`; confirm the speaker and displayed volume agree.
- Drag the slider slowly and rapidly; confirm the final value reaches the speaker.
- Rapidly press the iPhone volume buttons; confirm changes use the configured step
  and do not arrive out of order.
- Put iPhone output volume at 0% and 100% before opening Ampestra; confirm both
  physical directions still register after the app recenters the phone volume.
- Background and foreground Ampestra; confirm capture stops in the background,
  the previous phone volume is restored, and capture resumes when appropriate.

## Resilience and models

- Disable Wi-Fi briefly, restore it, and confirm the app reconnects without losing
  the selected speaker.
- Put the speaker into standby, confirm controls disable, then wake it with Power.
- Verify volume, mute, power, and every available source on LS50 Wireless II,
  LSX II, LSX II LT, and LS60 hardware available to the tester.
- Leave the app foregrounded for at least 15 minutes and confirm polling remains
  stable across playback and source changes.

Record the iPhone model/iOS version, speaker model/firmware, and any failed step
when reporting results.

## Layout, interruptions, and widgets

- In portrait and landscape, select the largest accessibility text size and
  trigger a long connection error. Scroll to and use volume, power, and source.
- Repeat on iPad in narrow split windows; confirm labels and menus are readable.
- Start and end a phone call or another audio interruption; confirm hardware
  volume capture stops and resumes appropriately without changing phone audio
  unexpectedly.
- Add the controls widget, choose each saved speaker, and exercise its volume
  and mute buttons while the app is foregrounded, backgrounded, and locked.
- Follow [IOS_SIRI_TESTING.md](IOS_SIRI_TESTING.md) for overlapping commands,
  per-speaker forgetting, identity changes, and Wake-on-LAN.

Simulator regression coverage includes large accessibility text, a long error,
landscape scrolling, and selecting a source in the accessible picker. Physical audio, permissions,
Siri delivery, widget execution, and Wake-on-LAN remain device sign-off checks.
