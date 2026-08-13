#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Ampestra"
UPDATE_REF="${1:-main}"

if [[ "$UPDATE_REF" == "" ]]; then
  UPDATE_REF="main"
fi

if [[ ! -d ".git" ]]; then
  echo "This is not a git checkout."
  exit 2
fi

if [[ ! -x "./script/install_app.sh" ]]; then
  echo "Missing ./script/install_app.sh."
  exit 2
fi

if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "Source checkout has uncommitted changes. Commit or stash them before updating."
  exit 3
fi

echo "Fetching latest $APP_NAME source..."
git fetch --tags origin

if git show-ref --verify --quiet "refs/remotes/origin/$UPDATE_REF"; then
  echo "Updating branch $UPDATE_REF..."
  if git show-ref --verify --quiet "refs/heads/$UPDATE_REF"; then
    git switch "$UPDATE_REF"
  else
    git switch --track -c "$UPDATE_REF" "origin/$UPDATE_REF"
  fi
  git pull --ff-only origin "$UPDATE_REF"
elif git show-ref --verify --quiet "refs/tags/$UPDATE_REF"; then
  echo "Checking out tag $UPDATE_REF..."
  git switch --detach "$UPDATE_REF"
else
  echo "Cannot find origin/$UPDATE_REF or tag $UPDATE_REF."
  exit 4
fi

echo "Building and installing $APP_NAME..."
./script/install_app.sh --yes
