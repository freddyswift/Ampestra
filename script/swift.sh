#!/usr/bin/env bash
set -euo pipefail

# Runs SwiftPM with a usable developer directory.
#
# Some Command Line Tools installs include a `swift-package` binary that looks
# for BuildServerProtocol.framework in the wrong location and aborts before
# SwiftPM can run. When that CLT layout is detected, prefer an installed Xcode
# that carries the framework in the location SwiftPM expects. An explicit
# DEVELOPER_DIR from the caller always wins.
#
# If AMPESTRA_SWIFT_BUILD_SYSTEM is set, pass it through to SwiftPM build
# commands. This is intentionally opt-in: deprecated SwiftPM build systems are
# useful for diagnosing toolchain bugs, but the project default should remain
# the supported SwiftPM backend.

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  selected_developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"

  if [[ "$selected_developer_dir" == *CommandLineTools* ]]; then
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app; do
      developer_dir="$app/Contents/Developer"
      shared_framework="$app/Contents/SharedFrameworks/BuildServerProtocol.framework"

      if [[ -d "$developer_dir" && -d "$shared_framework" ]]; then
        export DEVELOPER_DIR="$developer_dir"
        break
      fi
    done
  fi
fi

if [[ "${1:-}" == "build" || "${1:-}" == "test" || "${1:-}" == "run" ]]; then
  build_system="${AMPESTRA_SWIFT_BUILD_SYSTEM:-}"
  has_build_system=false

  for arg in "$@"; do
    if [[ "$arg" == "--build-system" || "$arg" == --build-system=* ]]; then
      has_build_system=true
      break
    fi
  done

  if [[ -n "$build_system" && "$has_build_system" != true ]]; then
    command="$1"
    shift
    set -- "$command" --build-system "$build_system" "$@"
  fi
fi

exec swift "$@"
