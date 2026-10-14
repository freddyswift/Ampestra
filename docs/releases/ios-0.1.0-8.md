# Ampestra iOS 0.1.0 (8)

## Improvements

- Capture the native iPhone media-volume level before physical-button control starts, avoiding stale audio-session readings.
- Retry delayed restoration writes and confirm the original volume before ending the audio session when you leave Ampestra.
- Preserve the opening volume through speaker disconnections and cancel old restoration attempts when you reopen the app.
- Standardize corner radii across cards, buttons, icon badges, connection controls, Siri results and widgets.
- Include the widget refresh, last-sync and offline improvements from build 7.

Please test leaving Ampestra with the iPhone volume initially low, high and muted, then reopening it with a different volume. Check widget refresh and controls, and layouts at larger text sizes.

Internal TestFlight testing only. Automatic widget refresh timing is controlled by iOS.
