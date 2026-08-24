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

1. Change the speaker's DHCP address, reconnect to it in Ampestra, and verify
   existing shortcuts still resolve the same named speaker.
2. Put the speaker in standby and make it unreachable over HTTP.
3. Ask Siri to turn it on. If Ampestra learned a MAC address during discovery,
   it should send Wake-on-LAN, wait for the speaker to return, and then confirm
   power-on. Without a saved MAC address, Siri should explain why waking is not
   available.
