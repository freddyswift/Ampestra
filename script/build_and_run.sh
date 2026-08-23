#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT="$ROOT_DIR/script/swift.sh"
BINARY_NAME="Ampestra"
DEV_PAYLOAD_NAME="libAmpestraDevPayload.dylib"
BASE_BUNDLE_NAME="Ampestra"
BASE_BUNDLE_IDENTIFIER="com.freddyswift.ampestra.macos"
# macOS Local Network privacy includes the main executable UUID in its app
# identity. Keep the Dev launcher's UUID fixed across payload rebuilds. This is
# the UUID macOS has cached for the enabled Ampestra Dev Local Network row.
DEV_LAUNCHER_UUID="5D17FC99-0065-3096-AB78-BD6CEF30EB80"
CONFIGURATION="${CONFIGURATION:-debug}"
BUILD_VARIANT="${AMPESTRA_BUILD_VARIANT:-dev}"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"

show_logs=false
verify_launch=false
open_after_build=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)
      BUILD_VARIANT="dev"
      shift
      ;;
    --prod|--production)
      BUILD_VARIANT="production"
      shift
      ;;
    --logs|--telemetry)
      show_logs=true
      shift
      ;;
    --verify)
      verify_launch=true
      shift
      ;;
    --no-open|--stage-only)
      open_after_build=false
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--dev|--prod] [--verify] [--no-open] [--logs|--telemetry]

Builds and launches a local app bundle. Dev mode is the default and stages
"Ampestra Dev.app" so local runs are visually distinct from production.

Options:
  --dev        Stage the local bundle as Ampestra Dev.app (default).
  --prod       Stage the local bundle as Ampestra.app.
  --verify     Confirm the app process launches.
  --no-open    Build and stage the app bundle without launching it.
  --logs       Stream unified logs after launch.
  --telemetry  Alias for --logs.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

case "$BUILD_VARIANT" in
  dev|development|local)
    IS_DEV_BUILD=true
    BUNDLE_NAME="$BASE_BUNDLE_NAME Dev"
    BUNDLE_IDENTIFIER="$BASE_BUNDLE_IDENTIFIER.dev"
    EXECUTABLE_NAME="AmpestraDev"
    ;;
  prod|production|release)
    IS_DEV_BUILD=false
    BUNDLE_NAME="$BASE_BUNDLE_NAME"
    BUNDLE_IDENTIFIER="$BASE_BUNDLE_IDENTIFIER"
    EXECUTABLE_NAME="$BINARY_NAME"
    ;;
  *)
    echo "Unknown AMPESTRA_BUILD_VARIANT: $BUILD_VARIANT" >&2
    exit 2
    ;;
esac

default_development_signing_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Apple Development:/ { print $2; exit }'
}

default_distribution_signing_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application:/ { print $2; exit }'
}

if [[ -z "$SIGNING_IDENTITY" ]]; then
  if [[ "$IS_DEV_BUILD" == true ]]; then
    SIGNING_IDENTITY="$(default_development_signing_identity)"
  else
    SIGNING_IDENTITY="$(default_distribution_signing_identity)"
  fi

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
  fi
fi

APP_DIR="$ROOT_DIR/dist/$BUNDLE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$ROOT_DIR"

if [[ "$open_after_build" != true && "$verify_launch" == true ]]; then
  echo "--verify requires launching the app; remove --no-open." >&2
  exit 2
fi

if [[ "$open_after_build" != true && "$show_logs" == true ]]; then
  echo "--logs requires launching the app; remove --no-open." >&2
  exit 2
fi

if [[ "$open_after_build" == true ]]; then
  process_names=("$EXECUTABLE_NAME")

  for process_name in "${process_names[@]}"; do
    if pgrep -x "$process_name" >/dev/null; then
      killall "$process_name" >/dev/null 2>&1 || true
    fi
  done
  sleep 0.2
fi

swift_build() {
  if [[ "$CONFIGURATION" == "release" ]]; then
    "$SWIFT" build -c release "$@"
  else
    "$SWIFT" build "$@"
  fi
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

build_stable_dev_launcher() {
  local launcher_source="$ROOT_DIR/Support/AmpestraDevLauncher.c"
  local launcher_dir="$ROOT_DIR/.build/ampestra-dev-launcher"
  local launcher="$launcher_dir/AmpestraDev"
  local actual_uuid

  mkdir -p "$launcher_dir"
  if [[ ! -x "$launcher" || "$launcher_source" -nt "$launcher" ]]; then
    xcrun clang \
      -Os \
      -Wall \
      -Wextra \
      -Werror \
      -mmacosx-version-min=14.0 \
      "$launcher_source" \
      -o "$launcher"
  fi

  # Idempotent, and ensures a deliberately changed configured UUID takes
  # effect without requiring contributors to delete the cached launcher.
  "$SWIFT" "$ROOT_DIR/script/set_macho_uuid.swift" "$launcher" "$DEV_LAUNCHER_UUID"

  actual_uuid="$(/usr/bin/dwarfdump --uuid "$launcher" | awk 'NR == 1 { print $2 }')"
  if [[ "$actual_uuid" != "$DEV_LAUNCHER_UUID" ]]; then
    echo "Dev launcher UUID changed: expected $DEV_LAUNCHER_UUID, got $actual_uuid" >&2
    exit 2
  fi

  echo "$launcher"
}

codesign_app() {
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    # Re-sign all nested Sparkle code with the same ad-hoc identity, then sign
    # the host with local-only library validation disabled. Without this narrow
    # entitlement, dyld rejects an ad-hoc host loading Sparkle's nested code.
    codesign --force --sign - --options runtime --deep "$APP_DIR" >/dev/null
    codesign \
      --force \
      --sign - \
      --options runtime \
      --entitlements "$ROOT_DIR/Resources/DevAdHoc.entitlements" \
      "$APP_DIR" >/dev/null
  else
    codesign \
      --force \
      --sign "$SIGNING_IDENTITY" \
      --options runtime \
      --deep \
      --timestamp \
      "$APP_DIR" >/dev/null
  fi

  codesign --verify --deep --strict "$APP_DIR"
}

if [[ "$IS_DEV_BUILD" == true ]]; then
  swift_build --product AmpestraDevPayload
else
  swift_build --product Ampestra
fi
BIN_DIR="$(swift_build --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
cp "$ROOT_DIR/Sources/Ampestra/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ "$IS_DEV_BUILD" == true ]]; then
  DEV_LAUNCHER="$(build_stable_dev_launcher)"
  cp "$DEV_LAUNCHER" "$CONTENTS_DIR/MacOS/$EXECUTABLE_NAME"
  mkdir -p "$CONTENTS_DIR/Frameworks"
  cp "$BIN_DIR/$DEV_PAYLOAD_NAME" "$CONTENTS_DIR/Frameworks/$DEV_PAYLOAD_NAME"
else
  cp "$BIN_DIR/$BINARY_NAME" "$CONTENTS_DIR/MacOS/$EXECUTABLE_NAME"
fi
copy_embedded_frameworks "$BIN_DIR"
copy_bundle_resources

/usr/libexec/PlistBuddy -c "Set :CFBundleName $BUNDLE_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $BUNDLE_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE_NAME" "$CONTENTS_DIR/Info.plist"
if [[ "$BUNDLE_NAME" != "$BASE_BUNDLE_NAME" ]]; then
  /usr/libexec/PlistBuddy -c "Set :NSLocalNetworkUsageDescription $BUNDLE_NAME uses your local network to find and control compatible KEF speakers." "$CONTENTS_DIR/Info.plist"
fi

codesign_app

if [[ "$open_after_build" != true ]]; then
  echo "Staged $APP_DIR"
  exit 0
fi

/usr/bin/open -n "$APP_DIR"

if [[ "$verify_launch" == true ]]; then
  for _ in {1..30}; do
    if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
      echo "$BUNDLE_NAME launched"
      break
    fi
    sleep 0.2
  done

  if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
    echo "$BUNDLE_NAME did not appear to launch" >&2
    exit 1
  fi
fi

if [[ "$show_logs" == true ]]; then
  /usr/bin/log stream --style compact --info --predicate "process == '$EXECUTABLE_NAME'"
fi
