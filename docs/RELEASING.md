# Releasing Ampestra

The iOS and macOS editions are versioned independently:

- iOS starts at marketing version `0.1.0`. Keep that version while iterating on
  the beta and increment its build number before every App Store Connect upload.
- macOS keeps its existing release sequence. Increment both its marketing
  version and build number for every GitHub/Sparkle release.

The iOS source of truth is `project.yml`; the macOS source of truth is
`Sources/Ampestra/Info.plist`. Run `make version-check` to validate and print
both versions. The command does not require them to match.

## TestFlight

The iOS project uses automatic signing for team `3VNW72P883`. Before every
upload, increment its build number and regenerate the checked-in Xcode project:

```sh
make ios-bump-build
```

This changes only the iOS `CURRENT_PROJECT_VERSION`; it does not change the iOS
marketing version or either macOS version. Confirm the result with:

```sh
make ios-version-check
```

Create a signed archive without uploading it:

```sh
make ios-archive
```

After tests and release metadata are ready, archive and upload the build to App
Store Connect:

```sh
make ios-upload
```

The upload uses the Apple developer account configured in Xcode and preserves
the iOS version and build number declared by the project. App Store Connect
requires every uploaded build number for a marketing version to be new.

## macOS Sparkle Release

This app uses locally built release artifacts hosted on GitHub Releases:

- `Ampestra-vX.Y.Z.dmg` for people downloading the app
- `Ampestra-vX.Y.Z.zip` for Sparkle app updates
- `sparkle-appcast.xml` for Sparkle update metadata

GitHub Actions are not required.

Sparkle compares the macOS `CFBundleVersion` in the installed app with the
`sparkle:version` in the appcast. The GitHub tag identifies the release and
defaults to `v<CFBundleShortVersionString>`. iOS builds are not published as
GitHub Releases and do not need GitHub tags.

## Public Hosting

Sparkle needs unauthenticated access to `sparkle-appcast.xml` and the update zip. The
default feed URL points at this public GitHub repo:

```text
https://github.com/freddyswift/Ampestra/releases/latest/download/sparkle-appcast.xml
```

If the repo is ever made private, host `sparkle-appcast.xml`, the update zip, and the
DMG somewhere public, then pass the matching feed/download URLs to the release
scripts.

## One-Time Setup

Generate a Sparkle EdDSA key:

```sh
make sparkle-key
```

Keep the private key in Keychain. Save the printed public key for packaging:

```sh
make release-config
```

That writes `.env.release`, which is ignored by git.

Public releases should be notarized and stapled. Create a `notarytool` keychain
profile before publishing:

```sh
make notary-profile
```

The default profile name is `Ampestra`.

## Build A Release

After approval for the exact version and build, update both macOS values in `Sources/Ampestra/Info.plist`. For example,
after `1.0.4 (5)`, use `1.0.5 (6)`. Then validate and build from those committed
values with a clean working tree:

```sh
make check
./script/release.sh 1.0.5 --build 6 --tag v1.0.5 --notes "## Improvements

- Describe the changes in this release." --no-upload
```

The package command writes:

```text
dist/releases/Ampestra-v1.0.5.dmg
dist/releases/Ampestra-v1.0.5.zip
dist/releases/sparkle-appcast.xml
```

The DMG opens with `Ampestra.app` beside an `Applications` shortcut so
users can drag the app into `/Applications`. The zip remains the Sparkle update
archive.

Prebuilt releases are currently Apple Silicon (`arm64`) unless the release is
explicitly built as universal.

## Upload To GitHub

After approval for the exact release, run `make check` and upload from a clean
commit with brief Markdown notes:

```sh
./script/release.sh 1.0.5 --build 6 --tag v1.0.5 \
  --notes "## Improvements

- Describe the changes in this release." --upload
```

Uploads require a notary profile and a Developer ID signing identity. The
version and build must match the committed macOS plist, and the tag must be
`v<version>`. Before packaging, the script checks that any existing local or
remote tag points to the build commit. Tag lookup errors stop the upload. It
checks again after packaging and rejects changes to the working tree or HEAD.

Replacing an existing release requires separate explicit permission and
`--replace-assets`. This updates the DMG, zip, appcast, and GitHub release notes
with the supplied notes. It does not delete or move the tag.

After upload, verify the tag target, assets, signing/notarization, and the
appcast version, build, download URL, and release notes as required by
[AGENTS.md](../AGENTS.md). CI validates changes but does not publish releases.

## Dry Runs

For a local packaging check without appcast generation:

```sh
make release-test
```

Dry-run artifacts are written under `dist/test-releases`. Do not upload them.
Rebuild with the real Sparkle public key and notarization setup before
publishing.

## Useful Details

- `make ios-version-check` validates only iOS; `make macos-version-check`
  validates only macOS; `make version-check` validates both independently.
- macOS release scripts read `CFBundleShortVersionString` and `CFBundleVersion`
  from `Sources/Ampestra/Info.plist` unless `MACOS_VERSION` or `--build` is
  provided. `VERSION` remains a backwards-compatible Makefile alias.
- `SPARKLE_DOWNLOAD_URL_PREFIX` or `script/release.sh --download-url-prefix URL`
  can override the generated appcast download URL.
- `SPARKLE_FEED_URL` or `script/release.sh --feed-url URL` can override the feed
  URL embedded in the app.
- `NOTARY_PROFILE` controls notarization. Blank skips it for local packaging;
  uploads require it.
