#!/bin/bash

# Development helper for working on refresh-rate-toggle locally.
#
# Validates this working tree, syncs it into the installed plugin directory
# (~/.config/omarchy/plugins/refresh-rate-toggle), runs setup.sh, and reloads
# Hyprland and the shell plugin so local edits can be tested immediately
# before pushing to GitHub.
#
# Not needed by end users.

set -euo pipefail

PLUGIN_ID="refresh-rate-toggle"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"

fail() {
  echo "dev.sh: $*" >&2
  exit 1
}

echo "Validating $REPO_DIR"
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate "$REPO_DIR"
fi

if [[ ! -d $TARGET_DIR ]]; then
  fail "$TARGET_DIR does not exist; install the plugin first with: omarchy plugin add <url> --enable"
fi

# Align the installed git checkout's HEAD with this repo's HEAD so that once
# local changes are committed and pushed, `omarchy plugin update` can still
# fast-forward cleanly without complaining about local changes.
if [[ -d $REPO_DIR/.git && -d $TARGET_DIR/.git ]]; then
  git -C "$TARGET_DIR" fetch --quiet "$REPO_DIR" HEAD
  git -C "$TARGET_DIR" reset --hard FETCH_HEAD >/dev/null
  git -C "$TARGET_DIR" clean -fd --quiet
fi

# Copy current working-tree files (including any uncommitted edits) into the
# installed plugin directory, excluding .git.
rsync -a --delete --exclude='.git' "$REPO_DIR/" "$TARGET_DIR/"

"$TARGET_DIR/install/setup.sh"
hyprctl reload >/dev/null 2>&1 || true
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
