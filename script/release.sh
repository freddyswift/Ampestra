#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Sources/Ampestra/Info.plist"
APP_NAME="Ampestra"
APP_DISPLAY_NAME="Ampestra"
APPCAST_ASSET_NAME="sparkle-appcast.xml"
RELEASES_DIR="${RELEASE_DIR:-$ROOT_DIR/dist/releases}"

version="${AMPESTRA_VERSION:-}"
build_number="${AMPESTRA_BUILD:-}"
release_tag="${RELEASE_TAG:-}"
public_ed_key="${SPARKLE_PUBLIC_ED_KEY:-}"
notary_profile="${NOTARY_PROFILE:-}"
feed_url="${SPARKLE_FEED_URL:-}"
download_url_prefix="${SPARKLE_DOWNLOAD_URL_PREFIX:-}"
release_notes=""
upload_choice=""
skip_git_check=false
assume_defaults=false
generate_appcast=true
replace_assets=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [VERSION] [options]

Prompts for local release details, then builds a signed Sparkle release package
and GitHub download DMG.
GitHub Actions are not used.

Options:
  --version VERSION        App version, e.g. 1.0.0.
  --build BUILD            Bundle build number. Defaults to Info.plist.
  --tag TAG                GitHub release tag. Defaults to vVERSION.
  --feed-url URL           Sparkle appcast URL embedded in the app.
  --download-url-prefix URL
                           Prefix for archive URLs in the generated appcast.
  --public-ed-key KEY      Sparkle public EdDSA key.
  --notary-profile NAME    notarytool keychain profile. Required with --upload.
  --notes TEXT             GitHub release notes if uploading.
  --upload                 Upload artifacts with gh after packaging.
  --replace-assets         Replace assets if the GitHub release already exists.
  --no-upload              Do not upload artifacts.
  --no-appcast             Package the zip without generating a Sparkle appcast.
  --no-git-check           Allow packaging with uncommitted changes.
  --yes                    Accept defaults for optional prompts.
EOF
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local value

  if [[ "$assume_defaults" == true && -n "$default_value" ]]; then
    printf '%s' "$default_value"
    return
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " value
    printf '%s' "${value:-$default_value}"
  else
    read -r -p "$label: " value
    printf '%s' "$value"
  fi
}

prompt_yes_no() {
  local label="$1"
  local default_value="$2"
  local value
  local suffix

  if [[ "$assume_defaults" == true ]]; then
    [[ "$default_value" == true ]]
    return
  fi

  if [[ "$default_value" == true ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  read -r -p "$label $suffix " value
  case "$value" in
    "" )
      [[ "$default_value" == true ]]
      ;;
    [Yy]|[Yy][Ee][Ss] )
      return 0
      ;;
    * )
      return 1
      ;;
  esac
}

validate_version() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+){1,2}([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "Version should look like 1.0.0." >&2
    exit 2
  fi
}

ensure_clean_git() {
  if [[ "$skip_git_check" == true ]]; then
    return
  fi

  if ! git -C "$ROOT_DIR" diff --quiet ||
     ! git -C "$ROOT_DIR" diff --cached --quiet ||
     [[ -n "$(git -C "$ROOT_DIR" ls-files --others --exclude-standard)" ]]; then
    echo "Working tree has uncommitted changes." >&2
    echo "Commit or stash them first, or pass --no-git-check for a local test package." >&2
    exit 3
  fi
}

default_signing_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application:/ { print $2; exit }'
}

ensure_upload_ready() {
  local guard_upload_error=false

  if [[ -z "$notary_profile" ]]; then
    echo "--upload requires notarization. Set NOTARY_PROFILE or pass --notary-profile." >&2
    guard_upload_error=true
  fi

  local signing_identity="${CODESIGN_IDENTITY:-$(default_signing_identity)}"
  if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
    echo "--upload requires a Developer ID signing identity. Set CODESIGN_IDENTITY if auto-detection fails." >&2
    guard_upload_error=true
  fi

  if [[ "$guard_upload_error" == true ]]; then
    exit 2
  fi
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
    --download-url-prefix)
      download_url_prefix="$2"
      shift 2
      ;;
    --public-ed-key)
      public_ed_key="$2"
      shift 2
      ;;
    --notary-profile)
      notary_profile="$2"
      shift 2
      ;;
    --notes)
      release_notes="$2"
      shift 2
      ;;
    --upload)
      upload_choice=true
      shift
      ;;
    --replace-assets)
      replace_assets=true
      shift
      ;;
    --no-upload)
      upload_choice=false
      shift
      ;;
    --no-appcast)
      generate_appcast=false
      shift
      ;;
    --no-git-check)
      skip_git_check=true
      shift
      ;;
    --yes|-y)
      assume_defaults=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$version" ]]; then
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      version="$1"
      shift
      ;;
  esac
done

cd "$ROOT_DIR"

default_version="$(plist_value CFBundleShortVersionString)"
default_build="$(plist_value CFBundleVersion)"

if [[ -z "$version" ]]; then
  version="$(prompt_value "Version" "$default_version")"
fi
validate_version "$version"

if [[ -z "$build_number" ]]; then
  build_number="$(prompt_value "Build number" "$default_build")"
fi

if [[ -z "$release_tag" ]]; then
  release_tag="$(prompt_value "Release tag" "v$version")"
fi

if [[ -z "$public_ed_key" ]]; then
  public_ed_key="$(prompt_value "Sparkle public EdDSA key" "")"
fi

if [[ -z "$public_ed_key" ]]; then
  echo "Missing Sparkle public EdDSA key." >&2
  echo "Run .build/artifacts/sparkle/Sparkle/bin/generate_keys once, then rerun this script." >&2
  exit 2
fi

if [[ -z "$notary_profile" && "$assume_defaults" != true ]]; then
  notary_profile="$(prompt_value "Notary profile (blank skips notarization)" "")"
fi

if [[ -z "$upload_choice" ]]; then
  if prompt_yes_no "Upload to GitHub Releases after packaging?" false; then
    upload_choice=true
  else
    upload_choice=false
  fi
fi

if [[ "$upload_choice" == true && -z "$release_notes" ]]; then
  release_notes="$(prompt_value "Release notes" "$APP_DISPLAY_NAME $release_tag.")"
fi

if [[ "$upload_choice" == true && "$generate_appcast" != true ]]; then
  echo "--upload requires appcast generation. Remove --no-appcast." >&2
  exit 2
fi

if [[ "$upload_choice" == true ]]; then
  ensure_upload_ready
fi

ensure_clean_git

package_args=(
  --version "$version"
  --build "$build_number"
  --tag "$release_tag"
  --public-ed-key "$public_ed_key"
)

if [[ -n "$feed_url" ]]; then
  package_args+=(--feed-url "$feed_url")
fi

if [[ -n "$download_url_prefix" ]]; then
  package_args+=(--download-url-prefix "$download_url_prefix")
fi

if [[ -n "$notary_profile" ]]; then
  package_args+=(--notary-profile "$notary_profile")
fi

if [[ "$generate_appcast" != true ]]; then
  package_args+=(--no-appcast)
fi

"$ROOT_DIR/script/package_release.sh" "${package_args[@]}"

archive_path="$RELEASES_DIR/$APP_NAME-$release_tag.zip"
dmg_path="$RELEASES_DIR/$APP_NAME-$release_tag.dmg"
appcast_path="$RELEASES_DIR/$APPCAST_ASSET_NAME"

if [[ "$upload_choice" != true ]]; then
  echo
  echo "Release artifacts are ready:"
  echo "  $dmg_path"
  echo "  $archive_path"
  if [[ "$generate_appcast" == true ]]; then
    echo "  $appcast_path"
  fi
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is not installed, so upload cannot continue." >&2
  echo "Install GitHub CLI or upload these files manually:" >&2
  echo "  $dmg_path" >&2
  echo "  $archive_path" >&2
  echo "  $appcast_path" >&2
  exit 4
fi

if gh release view "$release_tag" >/dev/null 2>&1; then
  if [[ "$replace_assets" != true ]]; then
    echo "GitHub release $release_tag already exists." >&2
    echo "Pass --replace-assets to overwrite its DMG, zip, and appcast assets." >&2
    exit 5
  fi

  gh release delete-asset "$release_tag" "$APPCAST_ASSET_NAME" --yes >/dev/null 2>&1 || true
  gh release upload "$release_tag" "$dmg_path" "$archive_path" "$appcast_path" --clobber
else
  gh release create "$release_tag" \
    "$dmg_path" \
    "$archive_path" \
    "$appcast_path" \
    --title "$APP_DISPLAY_NAME $release_tag" \
    --notes "$release_notes" \
    --target "$(git rev-parse HEAD)"
fi

echo "Uploaded $release_tag to GitHub Releases."
