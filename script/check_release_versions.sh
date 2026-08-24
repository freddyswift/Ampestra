#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_INFO_PLIST="$ROOT_DIR/Sources/Ampestra/Info.plist"
PROJECT_SPEC="$ROOT_DIR/project.yml"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$MACOS_INFO_PLIST"
}

project_value() {
  local setting="$1"
  awk -v setting="$setting" '$1 == setting ":" { print $2; exit }' "$PROJECT_SPEC"
}

macos_version="$(plist_value CFBundleShortVersionString)"
macos_build="$(plist_value CFBundleVersion)"
ios_version="$(project_value MARKETING_VERSION)"
ios_build="$(project_value CURRENT_PROJECT_VERSION)"

if [[ -z "$ios_version" || -z "$ios_build" ]]; then
  echo "Could not read the iOS version from project.yml." >&2
  exit 1
fi

if [[ "$macos_version" != "$ios_version" || "$macos_build" != "$ios_build" ]]; then
  echo "Ampestra release versions do not match:" >&2
  echo "  macOS: $macos_version ($macos_build)" >&2
  echo "  iOS:   $ios_version ($ios_build)" >&2
  exit 1
fi

echo "Ampestra release version: $ios_version ($ios_build) on iOS and macOS"
