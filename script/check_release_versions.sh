#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_INFO_PLIST="$ROOT_DIR/Sources/Ampestra/Info.plist"
IOS_INFO_PLIST="$ROOT_DIR/iOS/AmpestraMobile/Info.plist"
PROJECT_SPEC="$ROOT_DIR/project.yml"

check_ios=false
check_macos=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--ios | --macos]

Validates the independently versioned Ampestra apps. With no option, validates
and prints both versions.
EOF
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$MACOS_INFO_PLIST"
}

project_value() {
  local setting="$1"
  awk -v setting="$setting" '$1 == setting ":" { print $2; exit }' "$PROJECT_SPEC"
}

validate_marketing_version() {
  local platform="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$platform marketing version must contain three numeric components, such as 0.1.0: $value" >&2
    exit 1
  fi
}

validate_build_number() {
  local platform="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$platform build number must be a positive integer: $value" >&2
    exit 1
  fi
}

validate_ios() {
  local version
  local build
  local plist_version
  local plist_build

  version="$(project_value MARKETING_VERSION)"
  build="$(project_value CURRENT_PROJECT_VERSION)"

  if [[ -z "$version" || -z "$build" ]]; then
    echo "Could not read the iOS version from project.yml." >&2
    exit 1
  fi

  validate_marketing_version "iOS" "$version"
  validate_build_number "iOS" "$build"

  plist_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$IOS_INFO_PLIST")"
  plist_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$IOS_INFO_PLIST")"

  if [[ "$plist_version" != '$(MARKETING_VERSION)' ||
        "$plist_build" != '$(CURRENT_PROJECT_VERSION)' ]]; then
    echo "The iOS Info.plist must inherit MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml." >&2
    exit 1
  fi

  echo "iOS:   $version ($build)"
}

validate_macos() {
  local version
  local build

  version="$(plist_value CFBundleShortVersionString)"
  build="$(plist_value CFBundleVersion)"

  validate_marketing_version "macOS" "$version"
  validate_build_number "macOS" "$build"

  echo "macOS: $version ($build)"
}

case "${1:-}" in
  "")
    check_ios=true
    check_macos=true
    ;;
  --ios)
    check_ios=true
    ;;
  --macos)
    check_macos=true
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

if [[ "$check_ios" == true && "$check_macos" == true ]]; then
  echo "Ampestra app versions (independent):"
fi

if [[ "$check_ios" == true ]]; then
  validate_ios
fi

if [[ "$check_macos" == true ]]; then
  validate_macos
fi
