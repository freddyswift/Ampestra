# Ampestra iOS 0.1.0 (10)

## Connection reliability

- Use compatible KEF status requests and one HTTP connection per client.
- Automatically retry temporary connection failures while Ampestra is open.
- Cancel pending requests and retries when leaving the app or changing speakers.
- Preserve saved-speaker identity checks throughout reconnection.

Internal TestFlight testing only.
