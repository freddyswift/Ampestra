#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_SPEC="$ROOT_DIR/project.yml"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to bump the iOS build and regenerate the Xcode project." >&2
  exit 1
fi

setting_count="$(awk '$1 == "CURRENT_PROJECT_VERSION:" { count += 1 } END { print count + 0 }' "$PROJECT_SPEC")"
current_build="$(awk '$1 == "CURRENT_PROJECT_VERSION:" { print $2; exit }' "$PROJECT_SPEC")"

if [[ "$setting_count" != "1" ]]; then
  echo "Expected exactly one CURRENT_PROJECT_VERSION in project.yml; found $setting_count." >&2
  exit 1
fi

if [[ ! "$current_build" =~ ^[1-9][0-9]*$ ]]; then
  echo "The current iOS build number must be a positive integer: $current_build" >&2
  exit 1
fi

next_build="$((current_build + 1))"
temporary_spec="$(mktemp "$ROOT_DIR/project.yml.XXXXXX")"

cleanup() {
  if [[ -f "${temporary_spec:-}" ]]; then
    rm -f "$temporary_spec"
  fi
}
trap cleanup EXIT

awk -v next_build="$next_build" '
  $1 == "CURRENT_PROJECT_VERSION:" {
    sub(/CURRENT_PROJECT_VERSION:[[:space:]]*[0-9]+/, "CURRENT_PROJECT_VERSION: " next_build)
  }
  { print }
' "$PROJECT_SPEC" > "$temporary_spec"

mv "$temporary_spec" "$PROJECT_SPEC"
temporary_spec=""

cd "$ROOT_DIR"
xcodegen generate --spec project.yml

echo "Incremented the iOS build number from $current_build to $next_build."
