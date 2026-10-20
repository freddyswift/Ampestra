# Ampestra iOS 0.1.0 (9)

## Improvements

- Preserve the opening iPhone volume through temporary interruptions and rapid app switching.
- Recheck the native volume control on reopening instead of trusting stale audio-session readings.
- Wait for delayed native-control setup before capturing physical volume-button presses.
- Keep unfinished restores from saving the temporary capture volume, and discard old targets when an attempt ends.
- Begin restoration earlier when leaving the app, with bounded retries and confirmation before audio-session teardown.
- Include the widget refresh, last-sync and offline improvements, plus consistent corner radii throughout the app.

Please test opening and leaving Ampestra with iPhone volume initially muted, low and high. Also try changing phone volume between visits, returning quickly, opening Control Centre and switching speakers. Physical system-volume restoration still needs real-iPhone verification.

Internal TestFlight testing only. Automatic widget refresh timing is controlled by iOS.
