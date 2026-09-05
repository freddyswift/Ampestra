#!/usr/bin/env bash
# Sourced by release.sh; these checks never create or move a tag.

validate_release_metadata() {
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Release version must have three numeric components." >&2; return 2;
  }
  [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || {
    echo "Release build must be a positive integer." >&2; return 2;
  }
  [[ "$release_tag" == "v$version" ]] || {
    echo "Release tag must be v$version." >&2; return 2;
  }
  if [[ "$upload_choice" == true ]]; then
    [[ "$version" == "$default_version" && "$build_number" == "$default_build" ]] || {
      echo "Upload metadata must match the committed Info.plist." >&2; return 2;
    }
    [[ "$skip_git_check" != true ]] || {
      echo "Uploads require a clean committed working tree." >&2; return 2;
    }
  fi
}

verify_release_tag_target() {
  local local_target remote_refs remote_target status
  if git show-ref --verify --quiet "refs/tags/$release_tag"; then
    local_target="$(git rev-parse "refs/tags/$release_tag^{commit}")" || return
    [[ "$local_target" == "$release_commit" ]] || {
      echo "Local tag $release_tag does not point to the build commit." >&2; return 2;
    }
  fi
  if remote_refs="$(git ls-remote --exit-code origin "refs/tags/$release_tag" "refs/tags/$release_tag^{}")"; then
    remote_target="$(printf '%s\n' "$remote_refs" | awk 'NR == 1 { target = $1 } /\^\{\}$/ { target = $1 } END { print target }')"
    [[ "$remote_target" == "$release_commit" ]] || {
      echo "Remote tag $release_tag does not point to the build commit." >&2; return 2;
    }
  else
    status=$?
    [[ "$status" == 2 ]] || {
      echo "Could not verify the remote release tag; upload stopped." >&2; return "$status";
    }
  fi
}

check_existing_release() {
  local repository error_file
  repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || return
  error_file="$(mktemp)" || return
  if gh api "repos/$repository/releases/tags/$release_tag" >/dev/null 2>"$error_file"; then
    release_exists=true
    rm -f "$error_file"
    [[ "$replace_assets" == true ]] || {
      echo "Release $release_tag already exists; explicit --replace-assets is required." >&2; return 5;
    }
  else
    if ! grep -q '(HTTP 404)' "$error_file"; then
      cat "$error_file" >&2
      rm -f "$error_file"
      return 4
    fi
    rm -f "$error_file"
    release_exists=false
  fi
}
