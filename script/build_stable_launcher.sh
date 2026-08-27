#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT="$ROOT_DIR/script/swift.sh"
LAUNCHER_SOURCE="$ROOT_DIR/Support/AmpestraLauncher.c"

if [[ $# -ne 2 ]]; then
  echo "Usage: $(basename "$0") <launcher-name> <uuid>" >&2
  exit 2
fi

launcher_name="$1"
launcher_uuid="$2"

if [[ ! "$launcher_name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
  echo "Invalid launcher name: $launcher_name" >&2
  exit 2
fi

launcher_dir="$ROOT_DIR/.build/ampestra-launchers/$launcher_name"
launcher="$launcher_dir/$launcher_name"

mkdir -p "$launcher_dir"
if [[ ! -x "$launcher" || "$LAUNCHER_SOURCE" -nt "$launcher" ]]; then
  xcrun clang \
    -Os \
    -Wall \
    -Wextra \
    -Werror \
    -mmacosx-version-min=14.0 \
    "$LAUNCHER_SOURCE" \
    -o "$launcher"
fi

# Apply the configured UUID on every run so changing the configuration cannot
# leave a stale cached launcher behind.
"$SWIFT" "$ROOT_DIR/script/set_macho_uuid.swift" "$launcher" "$launcher_uuid"

actual_uuid="$(/usr/bin/dwarfdump --uuid "$launcher" | awk 'NR == 1 { print $2 }')"
if [[ "$actual_uuid" != "$launcher_uuid" ]]; then
  echo "Launcher UUID changed: expected $launcher_uuid, got $actual_uuid" >&2
  exit 2
fi

printf '%s\n' "$launcher"
