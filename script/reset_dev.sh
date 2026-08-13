#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_APP_DIR="$ROOT_DIR/dist/KEF Companion Dev.app"
DEV_BUNDLE_ID="com.freddyswift.KEFCompanion.dev"
PROD_BUNDLE_ID="com.freddyswift.KEFCompanion"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

include_production_permissions=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--include-production-permissions]

Removes the local KEF Companion Dev bundle, clears its saved preferences, and
resets every macOS privacy decision that tccutil supports for the Dev bundle.

macOS does not provide a supported way to return Local Network access to its
undetermined state on every OS release. `tccutil reset All` is still used so
Local Network is cleared automatically on releases where Apple supports it.

Options:
  --include-production-permissions
      Also reset the production KEF Companion privacy decisions. Use this only if
      an older dev build was granted permissions before it had a separate dev
      bundle identifier.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-production-permissions)
      include_production_permissions=true
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

kill_process_name() {
  local process_name="$1"

  if pgrep -x "$process_name" >/dev/null; then
    echo "Stopping $process_name..."
    killall "$process_name" >/dev/null 2>&1 || true
    sleep 0.2
  fi
}

kill_dev_app_path_processes() {
  local executable_dir="$DEV_APP_DIR/Contents/MacOS/"
  local pids

  pids="$(
    ps -axo pid=,command= |
      awk -v executable_dir="$executable_dir" '{
        pid = $1
        $1 = ""
        sub(/^ +/, "")
        if (index($0, executable_dir) == 1) {
          print pid
        }
      }'
  )"

  if [[ -z "$pids" ]]; then
    return
  fi

  echo "Stopping processes launched from $DEV_APP_DIR..."
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done <<<"$pids"
  sleep 0.2
}

reset_privacy_for_bundle() {
  local bundle_id="$1"

  echo "Resetting macOS privacy permissions for $bundle_id..."
  if ! tccutil reset All "$bundle_id"; then
    echo "Full privacy reset was unavailable; resetting keyboard permissions individually."
    tccutil reset Accessibility "$bundle_id" || true
    tccutil reset ListenEvent "$bundle_id" || true
  fi
}

reset_preferences_for_bundle() {
  local bundle_id="$1"

  echo "Clearing saved preferences for $bundle_id..."
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
}

register_dev_bundle() {
  if [[ ! -d "$DEV_APP_DIR" ]]; then
    echo "Staging KEF Companion Dev so macOS can identify its bundle id..."
    "$ROOT_DIR/script/build_and_run.sh" --no-open
  fi

  if [[ ! -d "$DEV_APP_DIR" ]]; then
    return
  fi

  "$LSREGISTER" -f "$DEV_APP_DIR" >/dev/null 2>&1 || true
}

kill_process_name "KEFCompanionDev"
kill_dev_app_path_processes
reset_preferences_for_bundle "$DEV_BUNDLE_ID"
register_dev_bundle

reset_privacy_for_bundle "$DEV_BUNDLE_ID"

if [[ "$include_production_permissions" == true ]]; then
  echo "Also resetting production KEF Companion permissions."
  reset_privacy_for_bundle "$PROD_BUNDLE_ID"
fi

rm -rf "$DEV_APP_DIR"
echo "Removed $DEV_APP_DIR"

echo "KEF Companion Dev reset complete."
