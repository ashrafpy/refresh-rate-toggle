#!/bin/bash

# Wire the refresh-rate-toggle plugin into Hyprland and the shell.
#
# `omarchy plugin add` clones the plugin directory, and when enabled with
# `--enable`, Service.qml runs `setup.sh --auto` automatically to install the
# files outside the plugin directory that Hyprland and the shell need:
#
#   ~/.config/hypr/monitor-refresh-rate.lua   the shim Hyprland's Lua requires
#   ~/.config/hypr/monitors.lua               the calls into the plugin
#   ~/.config/hypr/bindings.lua               the keybindings
#   ~/.local/bin/omarchy-monitor-refresh-rate the command, callable by name
#   ~/.config/omarchy/extensions/omarchy-menu.jsonc  the Hardware menu entry
#
# Running `setup.sh` directly is also supported and idempotent. Pass
# `--uninstall` to cleanly remove the external files and config blocks.

set -uo pipefail

PLUGIN_ID="refresh-rate-toggle"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
BIN_DIR="${XDG_LOCAL_BIN:-$HOME/.local/bin}"
SHIM="$HYPR_DIR/monitor-refresh-rate.lua"
WRAPPER="$BIN_DIR/omarchy-monitor-refresh-rate"
MONITORS_LUA="$HYPR_DIR/monitors.lua"
BINDINGS_LUA="$HYPR_DIR/bindings.lua"
MENU_JSONC="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"

mode="manual"
hypr_changed=0

while (($#)); do
  case $1 in
  --auto)
    mode="auto"
    shift
    ;;
  --uninstall)
    mode="uninstall"
    shift
    ;;
  -h | --help)
    cat <<'USAGE'
Usage: setup.sh [--auto|--uninstall]

Options:
  (none)        install or refresh the plugin's external files and reload
  --auto        quietly ensure external files are up to date (used by Service.qml)
  --uninstall   remove the plugin's external files and config blocks
  -h, --help    show this help
USAGE
    exit 0
    ;;
  *)
    echo "setup.sh: unknown option: $1" >&2
    exit 1
    ;;
  esac
done

fail() {
  echo "setup.sh: $*" >&2
  exit 1
}

say() {
  [[ $mode == "auto" ]] && return
  echo "  $1"
}

# The marker that tells us a file has already been patched. Each file is
# identified by the thing that is unique to it, not by the plugin id: the
# monitors.lua block predates any mention of the id, and matching on the id
# would append a second copy of it.
MARKER_MONITORS='require("hypr.monitor-refresh-rate")'
MARKER_BINDINGS='omarchy-monitor-refresh-rate toggle'
MARKER_MENU='trigger.hardware.refresh-rate'

# ---------------------------------------------------------------------------
# 1. The Hyprland shim
# ---------------------------------------------------------------------------

install_shim() {
  local source="$PLUGIN_DIR/install/hypr-shim.lua"

  [[ -f $source ]] || fail "missing $source"

  if [[ -f $SHIM ]] && cmp -s "$source" "$SHIM"; then
    say "shim already up to date"
    return
  fi

  mkdir -p "$HYPR_DIR"
  cp "$source" "$SHIM"
  hypr_changed=1
  say "installed $SHIM"
}

# ---------------------------------------------------------------------------
# 2. The wrapper, so the command can be called by name
# ---------------------------------------------------------------------------

install_wrapper() {
  local source="$PLUGIN_DIR/install/command-wrapper"

  [[ -f $source ]] || fail "missing $source"

  if [[ -f $WRAPPER && -x $WRAPPER ]] && cmp -s "$source" "$WRAPPER"; then
    say "wrapper already up to date"
    return
  fi

  mkdir -p "$BIN_DIR"
  cp "$source" "$WRAPPER"
  chmod +x "$WRAPPER"
  say "installed $WRAPPER"
}

# ---------------------------------------------------------------------------
# 3. The calls into the plugin, from monitors.lua
# ---------------------------------------------------------------------------

install_monitors_lua() {
  local block

  block='
-- refresh-rate-toggle: reapply the refresh rate picked with
-- omarchy-monitor-refresh-rate. The rule has to follow the catch-all above,
-- which would otherwise claim the display and hand it back its preferred mode.
local refresh_rate = require("hypr.monitor-refresh-rate")
refresh_rate.apply(omarchy_monitor_scale)

-- Plugging a display in or out makes Hyprland hand the internal panel its
-- preferred mode, so re-apply the saved rate once the displays have settled.
refresh_rate.watch(omarchy_monitor_scale)

-- Omarchy'"'"'s clamshell handling moves the internal panel back to its
-- preferred mode without firing a monitor event, so watch for the drift and
-- put it back on the saved rate.
refresh_rate.heal()
'

  # A file that does not exist yet: create one with the catch-all rule the
  # block depends on, then the block itself.
  if [[ ! -f $MONITORS_LUA ]]; then
    mkdir -p "$HYPR_DIR"
    cat >"$MONITORS_LUA" <<'EOF'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = "auto"

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
EOF
    hypr_changed=1
    say "created $MONITORS_LUA"
  fi

  if grep -q "$MARKER_MONITORS" "$MONITORS_LUA"; then
    say "monitors.lua already patched"
    return
  fi

  # The block has to run after the catch-all rule, since a later rule wins.
  # Append it at the end of the file, which is after the catch-all in every
  # stock and hand-edited file.
  printf '%s\n' "$block" >>"$MONITORS_LUA"
  hypr_changed=1
  say "patched $MONITORS_LUA"
}

# ---------------------------------------------------------------------------
# 4. The keybindings
# ---------------------------------------------------------------------------

install_bindings_lua() {
  local block

  block='
-- Cycle the focused display between its refresh rates. The chosen rate is
-- saved and reapplied on every Hyprland reload, so it survives a reboot.
o.bind("SUPER + SHIFT + R", "Toggle refresh rate", "omarchy-monitor-refresh-rate toggle")

-- Open the refresh rate panel, which lists the rates each display offers.
o.bind("SUPER + SHIFT + ALT + R", "Refresh rate panel", "omarchy-shell shell toggle refresh-rate-toggle")
'

  if [[ ! -f $BINDINGS_LUA ]]; then
    mkdir -p "$HYPR_DIR"
    cat >"$BINDINGS_LUA" <<'EOF'
-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.
EOF
    hypr_changed=1
    say "created $BINDINGS_LUA"
  fi

  if grep -q "$MARKER_BINDINGS" "$BINDINGS_LUA"; then
    say "bindings.lua already patched"
    return
  fi

  printf '%s\n' "$block" >>"$BINDINGS_LUA"
  hypr_changed=1
  say "patched $BINDINGS_LUA"
}

# ---------------------------------------------------------------------------
# 5. The menu entry
# ---------------------------------------------------------------------------

install_menu_entry() {
  local entry='  "trigger.hardware.refresh-rate": {"icon":"󰍹","label":"Refresh Rate","action":"omarchy-shell shell summon refresh-rate-toggle"},'

  mkdir -p "$(dirname "$MENU_JSONC")"

  if [[ ! -f $MENU_JSONC ]]; then
    cat >"$MENU_JSONC" <<EOF
{
$entry
}
EOF
    say "created $MENU_JSONC"
    return
  fi

  if grep -q "$MARKER_MENU" "$MENU_JSONC"; then
    say "menu entry already present"
    return
  fi

  # The file is JSONC: comments and a trailing comma on the last entry. Add
  # ours before the closing brace.
  python3 - "$MENU_JSONC" "$entry" <<'PY'
import re
import sys

path, entry = sys.argv[1], sys.argv[2]

with open(path, encoding="utf-8") as handle:
    text = handle.read()

match = re.search(r"}\s*$", text)
if not match:
    sys.exit("setup.sh: could not find the closing brace of the menu file")

prefix = text[: match.start()].rstrip()
lines = prefix.split("\n")

# Walk backwards to find the last line containing non-comment JSON tokens so
# that if a comma is needed after a previous property, it is placed before any
# inline or trailing '//' comments rather than after a comment.
for idx in range(len(lines) - 1, -1, -1):
    line = lines[idx]
    comment_match = re.search(r"(^|[ \t])//", line)
    if comment_match:
        code = line[: comment_match.start()].rstrip()
        comment = line[comment_match.start() :]
    else:
        code = line.rstrip()
        comment = ""

    if not code:
        continue

    if not code.endswith("{") and not code.endswith(","):
        lines[idx] = code + "," + comment
    break

text = "\n".join(lines) + "\n" + entry + "\n}\n"

with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
  say "patched $MENU_JSONC"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall_all() {
  echo "Removing $PLUGIN_ID external files and config entries"

  if [[ -f $SHIM ]]; then
    rm -f "$SHIM"
    hypr_changed=1
    say "removed $SHIM"
  fi

  if [[ -f $WRAPPER ]]; then
    rm -f "$WRAPPER"
    say "removed $WRAPPER"
  fi

  if [[ -f $MONITORS_LUA ]] && grep -q "$MARKER_MONITORS" "$MONITORS_LUA"; then
    python3 - "$MONITORS_LUA" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

pattern = re.compile(
    r"\n*(?:--[^\n]*\n)*local refresh_rate = require\(\"hypr\.monitor-refresh-rate\"\)\n"
    r"refresh_rate\.apply\([^\n]*\)\n+"
    r"(?:--[^\n]*\n)*refresh_rate\.watch\([^\n]*\)\n+"
    r"(?:--[^\n]*\n)*refresh_rate\.heal\(\)\n*",
    re.MULTILINE,
)
new_text = pattern.sub("\n", text).rstrip() + "\n"
with open(path, "w", encoding="utf-8") as handle:
    handle.write(new_text)
PY
    hypr_changed=1
    say "cleaned $MONITORS_LUA"
  fi

  if [[ -f $BINDINGS_LUA ]] && grep -q "$MARKER_BINDINGS" "$BINDINGS_LUA"; then
    python3 - "$BINDINGS_LUA" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

pattern = re.compile(
    r"\n*(?:--[^\n]*\n)*o\.bind\([^\n]*omarchy-monitor-refresh-rate toggle[^\n]*\)\n+"
    r"(?:--[^\n]*\n)*o\.bind\([^\n]*refresh-rate-toggle[^\n]*\)\n*",
    re.MULTILINE,
)
new_text = pattern.sub("\n", text).rstrip() + "\n"
with open(path, "w", encoding="utf-8") as handle:
    handle.write(new_text)
PY
    hypr_changed=1
    say "cleaned $BINDINGS_LUA"
  fi

  if [[ -f $MENU_JSONC ]] && grep -q "$MARKER_MENU" "$MENU_JSONC"; then
    python3 - "$MENU_JSONC" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

pattern = re.compile(
    r"\n*(?:[ \t]*// Refresh rate control[^\n]*\n(?:[ \t]*//[^\n]*\n)*)?[ \t]*\"trigger\.hardware\.refresh-rate\"[^\n]*\n?",
    re.MULTILINE,
)
new_text = pattern.sub("\n", text)
new_text = re.sub(r"\n{3,}", "\n\n", new_text).rstrip() + "\n"
with open(path, "w", encoding="utf-8") as handle:
    handle.write(new_text)
PY
    say "cleaned $MENU_JSONC"
  fi

  if ((hypr_changed)); then
    hyprctl reload >/dev/null 2>&1 || true
  fi

  echo
  echo "Done. You can now remove the plugin from Omarchy with:"
  echo "  omarchy plugin remove $PLUGIN_ID --yes"
}

# ---------------------------------------------------------------------------

if [[ $mode == "uninstall" ]]; then
  uninstall_all
  exit 0
fi

[[ $mode == "auto" ]] || echo "Setting up $PLUGIN_ID"

install_shim
install_wrapper
install_monitors_lua
install_bindings_lua
install_menu_entry

if ((hypr_changed)); then
  hyprctl reload >/dev/null 2>&1 || true
fi

if [[ $mode == "manual" ]]; then
  # Ensure the plugin is enabled and loaded in omarchy-shell so the user does
  # not have to enable it or restart the shell by hand.
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  if omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and (.enabled | not))' >/dev/null 2>&1; then
    omarchy-plugin-enable "$PLUGIN_ID" >/dev/null 2>&1 || true
  fi

  echo
  echo "Done. Try:  SUPER + SHIFT + R       (cycle the rate)"
  echo "            SUPER + SHIFT + ALT + R (open the panel)"
fi
