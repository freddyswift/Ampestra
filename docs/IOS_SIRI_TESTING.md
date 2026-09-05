# iOS Siri and Shortcuts testing

Use a physical iPhone running iOS 27 or later. Siri invocation and local-network
permission behaviour cannot be fully validated in the simulator.

## Setup

1. Install and launch Ampestra, then allow Local Network access.
2. Connect to the speaker once and confirm its name, model, source, and volume
   appear in the remote.
3. Open **Settings → Siri & Shortcuts** in Ampestra. Confirm the Siri tip and
   native Shortcuts link are visible.
4. In Shortcuts, confirm these Ampestra actions are present: set power, set
   source, set volume, adjust volume, mute/unmute, control playback, and get
   status.

## Siri checks

Run each check while Ampestra is closed, and repeat the key power and volume
checks while the iPhone is locked:

- “Turn speakers on with Ampestra.”
- “Set speakers to TV with Ampestra.”
- “Set speaker volume with Ampestra,” then answer the volume prompt.
- “Turn speakers down with Ampestra.”
- “Mute speakers with Ampestra,” followed by unmute; unmute should restore the
  last nonzero volume.
- “Get speaker status with Ampestra.”
- For Wi-Fi or Bluetooth playback, test play, pause, next, and previous.

Confirm Siri names the selected speaker and reports a specific, actionable
error when the phone is off the speaker network, the speaker is in standby, or
no speaker has been saved.

## Address and wake recovery

1. Change the speaker's DHCP address. Commands must not try its historical IP.
   Reconnect explicitly in Ampestra. When discovery provides the same MAC,
   existing shortcuts should retain their saved speaker ID. A manual connection
   without a matching MAC may create a new record that must be selected in the
   shortcut. Legacy records without a model also require an explicit reconnect.
   Reassign the old address to another speaker and confirm it receives no command.
   A changed name/model at the confirmed address must ask for reconnection;
   confirming a different MAC must preserve and invalidate the old shortcut ID.
2. Put the speaker in standby and make it unreachable over HTTP.
3. Ask Siri to turn it on. If Ampestra learned a MAC address during discovery,
   it should send Wake-on-LAN, wait for the speaker to return, and then confirm
   power-on. Without a saved MAC address, Siri should explain why waking is not
   available.

## Multiple control surfaces

- At volume 40, overlap two `+5` commands from Siri, the remote, or a widget;
  confirm the final value is 50. Mix an absolute slider value with relative taps
  and confirm foreground tap order is preserved.
- Mute from one surface, then unmute from another; confirm the last audible
  volume is restored. Repeating unmute while already audible should do nothing.
- Save two speakers, forget the selected one, and confirm the other remains in
  Shortcuts and widgets and becomes the default when necessary.
- These checks assume a trusted local network. Snapshot name/model checks are
  consistency checks, not cryptographic device authentication.
