# Ampestra iOS 0.1.0 (7)

## Improvements

- Fetch current speaker volume and power state when the Home Screen widget refreshes.
- Add a refresh button and show the last sync time, with an offline indication when the speaker cannot be reached.
- Keep newer volume-command confirmations when a widget network reply arrives late.
- Save iPhone media volume when Ampestra opens and restore it when you leave, including users who previously enabled mute on exit.

Please test widget volume, mute and refresh with your saved speaker. Check that your iPhone volume returns to its original level after leaving Ampestra and that reopening saves the new level.

Internal TestFlight testing only. Automatic widget refresh timing is controlled by iOS.
