#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT="$ROOT_DIR/script/swift.sh"
APP_DISPLAY_NAME="Ampestra"
APP_EXECUTABLE="Ampestra"
STAGING_DIR="$ROOT_DIR/dist/production-staging.noindex"
APP_DIR="$STAGING_DIR/$APP_DISPLAY_NAME.app"
LEGACY_APP_DIR="$ROOT_DIR/dist/$APP_DISPLAY_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
INSTALL_DIR="/Applications"
INSTALL_APP="$INSTALL_DIR/$APP_DISPLAY_NAME.app"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
AMPESTRA_VERSION="${AMPESTRA_VERSION:-}"
AMPESTRA_BUILD="${AMPESTRA_BUILD:-}"

prompt=true
open_after_install=true
install_after_build=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] [--no-open] [--stage-only]

Builds $APP_DISPLAY_NAME.app from source, installs it into /Applications, and opens it.

Options:
  --yes         Replace any existing /Applications/$APP_DISPLAY_NAME.app without prompting.
  --no-open     Install the app but do not open it.
  --stage-only  Build dist/production-staging.noindex/$APP_DISPLAY_NAME.app without installing it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      prompt=false
      shift
      ;;
    --no-open)
      open_after_install=false
      shift
      ;;
    --stage-only)
      install_after_build=false
      open_after_install=false
      prompt=false
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

default_signing_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application:/ { print $2; exit }'
}

SIGNING_IDENTITY="${CODESIGN_IDENTITY:-$(default_signing_identity)}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

set_plist_string() {
  local key="$1"
  local value="$2"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$CONTENTS_DIR/Info.plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$CONTENTS_DIR/Info.plist"
  fi
}

set_plist_bool() {
  local key="$1"
  local value="$2"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$CONTENTS_DIR/Info.plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$CONTENTS_DIR/Info.plist"
  fi
}

configure_release_metadata() {
  if [[ -n "$AMPESTRA_VERSION" ]]; then
    set_plist_string "CFBundleShortVersionString" "$AMPESTRA_VERSION"
  fi

  if [[ -n "$AMPESTRA_BUILD" ]]; then
    set_plist_string "CFBundleVersion" "$AMPESTRA_BUILD"
  fi

  if [[ -z "$SPARKLE_FEED_URL" && -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    return
  fi

  if [[ -z "$SPARKLE_FEED_URL" || -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY must be provided together." >&2
    exit 2
  fi

  set_plist_string "SUFeedURL" "$SPARKLE_FEED_URL"
  set_plist_string "SUPublicEDKey" "$SPARKLE_PUBLIC_ED_KEY"
  set_plist_bool "SUEnableAutomaticChecks" "true"
}

copy_embedded_frameworks() {
  local bin_dir="$1"
  local frameworks_dir="$CONTENTS_DIR/Frameworks"

  if [[ ! -d "$bin_dir/Sparkle.framework" ]]; then
    echo "Missing Sparkle.framework in $bin_dir." >&2
    exit 2
  fi

  mkdir -p "$frameworks_dir"
  ditto "$bin_dir/Sparkle.framework" "$frameworks_dir/Sparkle.framework"
}

copy_bundle_resources() {
  local resources_dir="$CONTENTS_DIR/Resources"

  mkdir -p "$resources_dir"
  ditto "$ROOT_DIR/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"
  ditto "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$resources_dir/ThirdPartyNotices.txt"
}

codesign_app() {
  local codesign_args=(--force --sign "$SIGNING_IDENTITY" --options runtime --deep)

  if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign_args+=(--timestamp)
  fi

  codesign "${codesign_args[@]}" "$APP_DIR" >/dev/null
}

confirm_install() {
  if [[ "$prompt" != true || ! -t 0 ]]; then
    return 0
  fi

  if [[ -d "$INSTALL_APP" ]]; then
    read -r -p "Replace $INSTALL_APP? [Y/n] " reply
  else
    read -r -p "Install $APP_DISPLAY_NAME.app to $INSTALL_DIR? [Y/n] " reply
  fi

  case "$reply" in
    ""|[Yy]|[Yy][Ee][Ss])
      return 0
      ;;
    *)
      echo "Install cancelled."
      exit 0
      ;;
  esac
}

install_app() {
  echo "Installing $APP_DISPLAY_NAME.app to $INSTALL_DIR..."

  if rm -rf "$INSTALL_APP" 2>/dev/null && ditto "$APP_DIR" "$INSTALL_APP" 2>/dev/null; then
    return 0
  fi

  echo "macOS needs permission to write to $INSTALL_DIR."
  /usr/bin/osascript - "$APP_DIR" "$INSTALL_APP" <<'APPLESCRIPT'
on run argv
  set sourcePath to item 1 of argv
  set targetPath to item 2 of argv
  do shell script "rm -rf " & quoted form of targetPath & " && ditto " & quoted form of sourcePath & " " & quoted form of targetPath with administrator privileges
end run
APPLESCRIPT
}

cd "$ROOT_DIR"

if [[ "$install_after_build" == true ]]; then
  confirm_install
fi

if [[ "$install_after_build" == true ]] && pgrep -x "$APP_EXECUTABLE" >/dev/null; then
  echo "Closing the running copy of $APP_DISPLAY_NAME..."
  killall "$APP_EXECUTABLE" >/dev/null 2>&1 || true
  sleep 0.2
fi

echo "Building $APP_DISPLAY_NAME.app from source..."
"$SWIFT" build -c release
BIN_DIR="$("$SWIFT" build -c release --show-bin-path)"

# Production executables receive a new Mach-O UUID when rebuilt. A second
# indexed bundle with the production identifier can make macOS Local Network
# privacy alternate between identities and interrupt the installed app. Keep
# release staging out of Spotlight and remove the old indexed staging path.
if [[ -d "$LEGACY_APP_DIR" ]]; then
  lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -u "$LEGACY_APP_DIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$LEGACY_APP_DIR"
fi

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
cp "$ROOT_DIR/Sources/Ampestra/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/$APP_EXECUTABLE" "$CONTENTS_DIR/MacOS/$APP_EXECUTABLE"
copy_embedded_frameworks "$BIN_DIR"
copy_bundle_resources
configure_release_metadata

echo "Signing build with $SIGNING_IDENTITY..."
codesign_app
codesign --verify --deep --strict "$APP_DIR"

if [[ "$install_after_build" == true ]]; then
  install_app
fi

if [[ "$open_after_install" == true ]]; then
  echo "Opening $APP_DISPLAY_NAME..."
  /usr/bin/open -n "$INSTALL_APP"
fi

if [[ "$install_after_build" == true ]]; then
  echo "Installed $INSTALL_APP"
else
  echo "Staged $APP_DIR"
fi
