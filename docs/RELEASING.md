# Releasing Ampestra

The iOS and macOS editions use the same marketing version and build number for
each coordinated Ampestra release. Run `make version-check` before releasing to
confirm that `project.yml` and the macOS `Info.plist` still agree.

## TestFlight

The iOS project uses automatic signing for team `3VNW72P883`. Create a signed
archive without uploading it:

```sh
make ios-archive
```

After tests and release metadata are ready, archive and upload the build to App
Store Connect:

```sh
make ios-upload
```

The upload uses the Apple developer account configured in Xcode and preserves
the version and build number declared by the project. App Store Connect requires
each uploaded build number for a marketing version to be new.

## macOS Sparkle Release

This app uses locally built release artifacts hosted on GitHub Releases:

- `Ampestra-vX.Y.Z.dmg` for people downloading the app
- `Ampestra-vX.Y.Z.zip` for Sparkle app updates
- `sparkle-appcast.xml` for Sparkle update metadata

GitHub Actions are not required.

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

Make sure the working tree is clean, then build locally:

```sh
make release VERSION=1.0.0
```

The package command writes:

```text
dist/releases/Ampestra-v1.0.0.dmg
dist/releases/Ampestra-v1.0.0.zip
dist/releases/sparkle-appcast.xml
```

The DMG opens with `Ampestra.app` beside an `Applications` shortcut so
users can drag the app into `/Applications`. The zip remains the Sparkle update
archive.

Prebuilt releases are currently Apple Silicon (`arm64`) unless the release is
explicitly built as universal.

## Upload To GitHub

Let the release script upload with GitHub CLI:

```sh
make release-upload VERSION=1.0.0
```

Uploads require a notary profile and a Developer ID signing identity. If a
release for the tag already exists, rerun `script/release.sh` with
`--replace-assets` only when you intentionally want to overwrite its DMG, zip,
and appcast assets.

Or upload manually:

```sh
gh release create v1.0.0 \
  dist/releases/Ampestra-v1.0.0.dmg \
  dist/releases/Ampestra-v1.0.0.zip \
  dist/releases/sparkle-appcast.xml \
  --title "Ampestra v1.0.0" \
  --notes "Initial release."
```

## Dry Runs

For a local packaging check without appcast generation:

```sh
make release-test VERSION=1.0.0
```

Dry-run artifacts are written under `dist/test-releases`. Do not upload them.
Rebuild with the real Sparkle public key and notarization setup before
publishing.

## Useful Details

- Release scripts read `CFBundleShortVersionString` and `CFBundleVersion` from
  `Sources/Ampestra/Info.plist` unless `VERSION` or `--build` is provided.
- `SPARKLE_DOWNLOAD_URL_PREFIX` or `script/release.sh --download-url-prefix URL`
  can override the generated appcast download URL.
- `SPARKLE_FEED_URL` or `script/release.sh --feed-url URL` can override the feed
  URL embedded in the app.
- `NOTARY_PROFILE` controls notarization. Blank skips it for local packaging;
  uploads require it.
