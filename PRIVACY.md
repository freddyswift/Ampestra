# Privacy

Last updated: 24 August 2026

Ampestra is a local-first, unofficial remote for compatible KEF wireless
speakers. It does not require an Ampestra account and does not include
advertising, analytics, tracking SDKs, or developer-operated cloud services.

## Data the app handles

To discover and control a speaker, Ampestra may handle:

- the speaker's local hostname or IP address, name, model, selected source,
  power state, and volume;
- a speaker MAC address advertised on the local network, when available, for
  Wake-on-LAN;
- now-playing title, artist, album, and playback state reported by the speaker;
- app preferences such as the selected speaker, volume step, and optional
  hardware-volume-key behaviour.

This information is used to provide the remote-control features. Ampestra does
not send it to the project maintainer.

## Where data goes

Speaker discovery and control traffic stays between the device running
Ampestra and the selected speaker on the local network. Compatible KEF speakers
expose a local HTTP control API; that protocol is not encrypted by Ampestra.
Use Ampestra only on a network you trust.

When a command starts through Siri or Shortcuts, iOS provides the selected
action and parameters to Ampestra, which then contacts the speaker locally.
Siri request processing is controlled by the user's Apple and Siri settings
and is subject to Apple's privacy terms; Ampestra does not send Siri requests
to a developer-operated service.

Signed macOS release builds use Sparkle to check the public GitHub Releases
appcast. GitHub and the network carrying that request may receive ordinary
request metadata such as an IP address and user agent under their own policies.
Source builds do not perform in-app update checks.

## Local storage

Ampestra stores its preferences on the iPhone or Mac. Depending on the enabled
features, those preferences can include the last selected host, a discovered
MAC address, trusted speaker hosts, control settings, and onboarding state.
Choosing **Forget speaker** removes the saved speaker from the iPhone app.
Deleting the iPhone app normally removes its local container, subject to Apple
backup behaviour. Deleting the macOS application bundle does not necessarily
remove its preferences; those remain under the user's macOS account until
cleared separately.

## Permissions

- **Local Network** allows speaker discovery and direct local control.
- **Input Monitoring** and **Accessibility** are optional on macOS and are used
  only to route volume media-key events. Ampestra does not record typed text.
- The iPhone app observes output-volume changes when physical-button control is
  enabled. It does not request microphone access or record audio.

## Diagnostics and reports

Ampestra does not automatically upload diagnostics. If you submit an issue or
security report, you choose what to share. Remove private hostnames, IP
addresses, MAC addresses, network captures, and now-playing information unless
they are essential to the report.

## Changes and questions

Material changes to this policy will be made in this repository. For privacy
questions, open a GitHub issue that contains no sensitive information. Report
security concerns privately as described in [SECURITY.md](SECURITY.md).
