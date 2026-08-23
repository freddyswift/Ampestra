#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT="$ROOT_DIR/script/swift.sh"
APP_NAME="Ampestra"
APP_DISPLAY_NAME="Ampestra"
APPCAST_ASSET_NAME="sparkle-appcast.xml"
APP_DIR="$ROOT_DIR/dist/$APP_DISPLAY_NAME.app"
INFO_PLIST="$ROOT_DIR/Sources/Ampestra/Info.plist"
DEFAULT_FEED_URL="https://github.com/freddyswift/Ampestra/releases/latest/download/$APPCAST_ASSET_NAME"

version="${AMPESTRA_VERSION:-}"
build_number="${AMPESTRA_BUILD:-}"
release_tag="${RELEASE_TAG:-}"
feed_url="${SPARKLE_FEED_URL:-$DEFAULT_FEED_URL}"
public_ed_key="${SPARKLE_PUBLIC_ED_KEY:-}"
archives_dir="${RELEASE_DIR:-$ROOT_DIR/dist/releases}"
download_url_prefix="${SPARKLE_DOWNLOAD_URL_PREFIX:-}"
notary_profile="${NOTARY_PROFILE:-}"
release_build_system="${AMPESTRA_RELEASE_BUILD_SYSTEM:-native}"
generate_appcast=true
create_dmg=true
appcast_input_dir=""
dmg_staging_dir=""

cleanup_temp_dirs() {
  if [[ -n "${appcast_input_dir:-}" && -d "$appcast_input_dir" ]]; then
    rm -rf "$appcast_input_dir"
  fi

  if [[ -n "${dmg_staging_dir:-}" && -d "$dmg_staging_dir" ]]; then
    rm -rf "$dmg_staging_dir"
  fi
}

trap cleanup_temp_dirs EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") --public-ed-key KEY [options]

Builds a local signed release archive, GitHub download DMG, and Sparkle appcast.
GitHub Actions are not used; upload the generated files to GitHub Releases from
this Mac.

Options:
  --version VERSION        CFBundleShortVersionString. Defaults to Info.plist.
  --build BUILD            CFBundleVersion. Defaults to Info.plist.
  --tag TAG                GitHub release tag. Defaults to vVERSION.
  --feed-url URL           Sparkle appcast URL embedded in the app.
                           Default: $DEFAULT_FEED_URL
  --public-ed-key KEY      Sparkle public EdDSA key from generate_keys.
  --archives-dir PATH      Directory for release zips and the Sparkle appcast.
                           Default: dist/releases
  --download-url-prefix URL
                           Prefix for archive URLs in the generated appcast.
                           Default: GitHub release download URL for TAG.
  --notary-profile NAME    notarytool keychain profile. Also read from NOTARY_PROFILE.
  --no-dmg                 Build only the zip and appcast.
  --no-appcast             Build the zip without running generate_appcast.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="$2"
      shift 2
      ;;
    --build)
      build_number="$2"
      shift 2
      ;;
    --tag)
      release_tag="$2"
      shift 2
      ;;
    --feed-url)
      feed_url="$2"
      shift 2
      ;;
    --public-ed-key)
      public_ed_key="$2"
      shift 2
      ;;
    --archives-dir)
      archives_dir="$2"
      shift 2
      ;;
    --download-url-prefix)
      download_url_prefix="$2"
      shift 2
      ;;
    --notary-profile)
      notary_profile="$2"
      shift 2
      ;;
    --no-dmg)
      create_dmg=false
      shift
      ;;
    --no-appcast)
      generate_appcast=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

default_signing_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application:/ { print $2; exit }'
}

generate_sparkle_appcast() {
  local appcast_tool="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

  if [[ ! -x "$appcast_tool" ]]; then
    "$SWIFT" build -c release
  fi

  appcast_input_dir="$(mktemp -d "$ROOT_DIR/dist/appcast-input.XXXXXX")"
  cp "$archive_path" "$appcast_input_dir/"

  if ! compgen -G "$appcast_input_dir/$APP_NAME-*.zip" >/dev/null; then
    echo "No Sparkle zip archives found in $archives_dir." >&2
    exit 3
  fi

  "$appcast_tool" \
    --download-url-prefix "$download_url_prefix" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "$appcast_input_dir/$APPCAST_ASSET_NAME" \
    "$appcast_input_dir"

  if [[ ! -f "$appcast_input_dir/$APPCAST_ASSET_NAME" ]]; then
    echo "Sparkle did not write $APPCAST_ASSET_NAME." >&2
    exit 3
  fi

  cp "$appcast_input_dir/$APPCAST_ASSET_NAME" "$archives_dir/$APPCAST_ASSET_NAME"
  rm -rf "$appcast_input_dir"
  appcast_input_dir=""
}

create_release_dmg() {
  local output_path="$1"

  mkdir -p "$ROOT_DIR/dist"
  dmg_staging_dir="$(mktemp -d "$ROOT_DIR/dist/dmg-staging.XXXXXX")"
  ditto "$APP_DIR" "$dmg_staging_dir/$APP_DISPLAY_NAME.app"
  ln -s /Applications "$dmg_staging_dir/Applications"

  rm -f "$output_path"
  hdiutil create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$dmg_staging_dir" \
    -format UDZO \
    -ov \
    "$output_path" >/dev/null

  local signing_identity="${CODESIGN_IDENTITY:-$(default_signing_identity)}"
  if [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
    codesign \
      --force \
      --sign "$signing_identity" \
      --timestamp \
      --identifier "com.freddyswift.ampestra.macos.disk-image" \
      "$output_path"
    codesign --verify --verbose=2 "$output_path"
  elif [[ -n "$notary_profile" ]]; then
    echo "A Developer ID Application identity is required to sign the release DMG." >&2
    exit 2
  else
    echo "Skipping DMG signing because no Developer ID Application identity is available."
  fi

  rm -rf "$dmg_staging_dir"
  dmg_staging_dir=""
}

if [[ -z "$version" ]]; then
  version="$(plist_value CFBundleShortVersionString)"
fi

if [[ -z "$build_number" ]]; then
  build_number="$(plist_value CFBundleVersion)"
fi

if [[ -z "$release_tag" ]]; then
  release_tag="v$version"
fi

if [[ -z "$download_url_prefix" ]]; then
  download_url_prefix="https://github.com/freddyswift/Ampestra/releases/download/$release_tag/"
fi

if [[ -z "$public_ed_key" ]]; then
  echo "Missing Sparkle public EdDSA key." >&2
  echo "Run: .build/artifacts/sparkle/Sparkle/bin/generate_keys" >&2
  echo "Then pass the printed public key with --public-ed-key." >&2
  exit 2
fi

if [[ -z "$feed_url" ]]; then
  echo "Missing Sparkle feed URL." >&2
  exit 2
fi

cd "$ROOT_DIR"

echo "Cleaning cached SwiftPM products so the release uses the active Xcode SDK..."
"$SWIFT" package clean

echo "Building $APP_DISPLAY_NAME $version ($build_number) for $release_tag..."
AMPESTRA_SWIFT_BUILD_SYSTEM="$release_build_system" \
AMPESTRA_VERSION="$version" \
AMPESTRA_BUILD="$build_number" \
SPARKLE_FEED_URL="$feed_url" \
SPARKLE_PUBLIC_ED_KEY="$public_ed_key" \
./script/install_app.sh --stage-only

linked_sdk="$(/usr/bin/vtool -show-build "$APP_DIR/Contents/MacOS/$APP_NAME" | awk '/ sdk / { print $2; exit }')"
linked_sdk_major="${linked_sdk%%.*}"
if [[ -z "$linked_sdk" || ! "$linked_sdk_major" =~ ^[0-9]+$ || "$linked_sdk_major" -lt 26 ]]; then
  echo "Release executable was linked against SDK ${linked_sdk:-unknown}; SDK 26 or newer is required for native Liquid Glass." >&2
  echo "Use Xcode 26 or newer and a release build system that preserves the active SDK marker." >&2
  exit 2
fi
echo "Verified release executable is linked against SDK $linked_sdk."

codesign --verify --deep --strict "$APP_DIR"

if [[ -n "$notary_profile" ]]; then
  notary_zip="$ROOT_DIR/dist/$APP_NAME-notary.zip"
  rm -f "$notary_zip"
  ditto -c -k --keepParent "$APP_DIR" "$notary_zip"

  echo "Submitting $APP_DISPLAY_NAME to Apple notarization with profile $notary_profile..."
  xcrun notarytool submit "$notary_zip" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$APP_DIR"
  rm -f "$notary_zip"
else
  echo "Skipping notarization. Set NOTARY_PROFILE or pass --notary-profile to notarize locally."
fi

mkdir -p "$archives_dir"
archive_path="$archives_dir/$APP_NAME-$release_tag.zip"
dmg_path="$archives_dir/$APP_NAME-$release_tag.dmg"
rm -f "$archive_path"
ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent "$APP_DIR" "$archive_path"

if [[ "$generate_appcast" == true ]]; then
  generate_sparkle_appcast
fi

if [[ "$create_dmg" == true ]]; then
  create_release_dmg "$dmg_path"

  if [[ -n "$notary_profile" ]]; then
    echo "Submitting $dmg_path to Apple notarization with profile $notary_profile..."
    xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg_path"
  fi
fi

echo "Wrote $archive_path"
if [[ "$create_dmg" == true ]]; then
  echo "Wrote $dmg_path"
fi
if [[ "$generate_appcast" == true ]]; then
  echo "Wrote $archives_dir/$APPCAST_ASSET_NAME"
fi
