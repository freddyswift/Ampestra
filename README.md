# Ampestra

[![CI](https://github.com/freddyswift/Ampestra/actions/workflows/ci.yml/badge.svg)](https://github.com/freddyswift/Ampestra/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/freddyswift/Ampestra)](https://github.com/freddyswift/Ampestra/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Unofficial iPhone remote and macOS menu bar companion for KEF wireless speakers.

## Why Ampestra?

Ampestra keeps the controls used most often—power, source, speaker volume, and
playback—one tap or click away without replacing KEF Connect. It communicates
directly with the speaker on the local network, requires no Ampestra account,
and provides native controls tailored to iPhone and the macOS menu bar.

## Run on iPhone

1. Open `Ampestra.xcodeproj` in Xcode.
2. Select the **Ampestra iOS** scheme and your connected iPhone.
3. In **Signing & Capabilities**, choose your development team if Xcode does
   not select it automatically.
4. Press Run, then allow **Local Network** access on the phone.
5. Choose **Find speakers**, or enter the speaker's private IP address from
   your router or KEF Connect.

The iOS target requires iOS 27 or later. While the app is in the foreground,
its optional physical-button mode observes iPhone output-volume changes and
translates them into configurable speaker-volume steps. Capture stops when the
app leaves the foreground. By default the previous phone volume is restored;
an opt-in setting can instead mute iPhone media volume when the app enters the
background.

### Siri and Shortcuts

After connecting a speaker once, open **Settings → Siri & Shortcuts** in
Ampestra to see the native Siri tip or open the Shortcuts gallery. Ampestra
provides background actions for power, source, exact or stepped volume,
mute/unmute, playback, and speaker status. For example:

- “Turn speakers on with Ampestra”
- “Set speakers to TV with Ampestra”
- “Turn speakers down with Ampestra”
- “Get speaker status with Ampestra”

Siri asks for any value that is not present in the phrase. Commands still go
directly from the iPhone to the saved speaker over the local network. Power-on
can fall back to Wake-on-LAN when Ampestra learned the speaker's MAC address.

If you edit `project.yml`, regenerate the checked-in Xcode project with:

```sh
make ios-project
```

Simulator build and test shortcuts are `make ios-build` and `make ios-test`.
Maintainers can create a signed App Store archive with `make ios-archive`; the
separate `make ios-upload` command archives and uploads it to App Store Connect.

## Download

Download the latest `Ampestra-*.dmg` from
[GitHub Releases](https://github.com/freddyswift/Ampestra/releases).

Prebuilt releases currently require macOS 14 or later on Apple Silicon.

Open the DMG, then drag `Ampestra.app` into `Applications`.

## Compatibility

The iPhone app supports iOS 27 or later. The menu bar app supports macOS 14 or
later. CI builds and tests the macOS app on the oldest supported macOS runner
and on the current macOS 26 release environment. If you use macOS 14 or 15,
please report any launch, permissions, networking, or UI issues.

Ampestra works with KEF speakers that expose the local HTTP control API:

- KEF LS50 Wireless II
- KEF LSX II / LSX II LT
- KEF LS60

The original LS50 Wireless and LSX gen 1 are not supported.

## Features

- Finds speakers with Bonjour auto-discovery
- Supports manual local host/IP fallback
- Controls power, source, volume, and playback
- Provides native iOS 27 Siri and Shortcuts actions that can run in the
  background and address saved speakers by name
- Provides an iPhone remote with large volume controls and a foreground-only
  physical volume-button mode
- Shows now-playing metadata and previous/play-pause/next controls for WiFi and
  Bluetooth playback
- Can route keyboard volume keys to the speaker, or auto-switch them back to macOS when playback is paused
- Sends Wake-on-LAN when a speaker MAC address is discovered

## Permissions

Ampestra asks for Local Network access after you choose **Find Speakers** or
connect to a manual local address,
because it cannot discover or control a speaker without that access. It does not
trigger the prompt merely by launching in the background.

On iPhone, optional physical-button control observes media-output-volume
changes so side-button presses can be translated into speaker volume commands.
Ampestra does not request microphone access or record audio.

Keyboard volume-key control is optional. If you choose Auto or KEF mode, macOS
also asks for broad Input Monitoring and Accessibility privileges. Ampestra
uses those permissions only to handle volume media-key events; it does not log
or store keystrokes.

- Input Monitoring, to receive keyboard volume-key events
- Accessibility, to intercept those events before macOS changes system volume

The app checks those settings again when you return to it. A restart is offered
only if macOS grants both permissions but refuses to activate the key listener.

## Build From Source

Requires macOS 14 or later and the Xcode/Swift toolchain. Source builds target
the architecture of the Mac doing the build. If you do not have the command line
tools installed, run:

```sh
xcode-select --install
```

Install from source:

```sh
git clone https://github.com/freddyswift/Ampestra.git
cd Ampestra
make install
```

That builds `Ampestra.app`, asks before replacing any existing copy in
`/Applications`, installs it, and opens the app.

Update an installed source build:

```sh
git pull --ff-only
make install
```

Source builds do not update themselves from inside the app. The Settings update
button is enabled only for signed release builds with a Sparkle appcast.

Contributor commands:

- `make run` builds and launches the development app.
- `make dev-reset` removes the development app and resets its optional keyboard permissions.
- `make dev-fresh` runs that targeted reset, then rebuilds and launches the development app.
- `make app` stages `dist/production-staging.noindex/Ampestra.app` so macOS
  does not register a second production Local Network identity.
- `make clean` removes build artifacts.

macOS does not expose a supported way to reset Local Network access to its
undetermined state. Development builds therefore keep one stable bundle identity
instead of creating new identities to manufacture fresh prompts.

Both development and production bundles use a small, fixed main launcher and
load the rebuilt Swift app from `Contents/Frameworks`. This keeps the executable
UUID used by macOS Local Network privacy stable across source rebuilds and app
updates while the versioned Swift payload continues to change normally.

Use the `make` commands or `./script/swift.sh ...` for local SwiftPM work in
this repository. On some macOS/Xcode beta setups, raw `swift ...` can resolve to
a broken Command Line Tools SwiftPM install; the wrapper selects a working Xcode
toolchain. Prefer `make run` over `swift run` for manual testing, because it
launches a signed `.app` bundle with Info.plist and embedded frameworks rather
than a bare executable.

Maintainer release instructions live in [docs/RELEASING.md](docs/RELEASING.md).

## Privacy

Ampestra does not include analytics, telemetry, advertising, accounts, or
bundled credentials.

The app uses Bonjour to discover compatible speakers on the local network,
connects to speakers over their local HTTP API, and may read now-playing
metadata from the connected speaker. Manual speaker hosts, the last connected
host, stable saved-speaker IDs, and app settings are stored locally in the
app's preferences. Discovered MAC addresses are used only for Wake-on-LAN.

Signed release builds use Sparkle to check GitHub Releases for app updates.

The complete data-flow, local-storage, permission, and update-check disclosures
are in [PRIVACY.md](PRIVACY.md). Security reporting and the local-network threat
model are in [SECURITY.md](SECURITY.md).

## Important disclosures

- Ampestra is an independent, unofficial project. It is not affiliated with,
  authorised by, sponsored by, or endorsed by KEF.
- Speaker control relies on a local HTTP API exposed by compatible KEF
  firmware. Firmware changes may alter or remove behaviour without notice.
- Commands such as power, source, playback, and volume take effect on the
  selected physical speaker. Confirm the selected speaker and volume before
  use, particularly on shared networks or high-powered systems.
- The project is provided under the MIT License without warranty. Compatibility
  listings describe tested intent, not a guarantee for every firmware or
  network configuration.

KEF and referenced speaker product names belong to their respective owners and
are used only to describe interoperability.

## Support

This is a personal project maintained on a best-effort basis. GitHub issues are
welcome for reproducible bugs, but support, feature work, and response times are
not guaranteed. Remove private network and playback information before posting
diagnostics. Report security issues privately according to
[SECURITY.md](SECURITY.md).

## Attribution

This project is based on [nickvanw/KEFControl](https://github.com/nickvanw/KEFControl), licensed under the MIT License.

Third-party dependency notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](LICENSE).
