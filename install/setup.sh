#!/bin/bash

# Wire the refresh-rate-toggle plugin into Hyprland and the shell.
#
# `omarchy plugin add` only clones the plugin directory. The plugin also
# needs four things outside it, because Hyprland and the shell cannot reach
# into a plugin directory on their own:
#
#   ~/.config/hypr/monitor-refresh-rate.lua   the shim Hyprland's Lua requires
#   ~/.config/hypr/monitors.lua                the calls into the plugin
#   ~/.config/hypr/bindings.lua               the keybindings
#   ~/.local/bin/omarchy-monitor-refresh-rate  the command, callable by name
#
# This script installs all four. It is idempotent: running it twice changes
# nothing the second time.

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

fail() {
  echo "setup.sh: $*" >&2
  exit 1
}

say() {
  echo "  $1"
}

# The marker that tells us a file has already been patched. Each file is
# identified by the thing that is unique to it, not by the plugin id: the
# monitors.lua block predates any mention of the id, and matching on the id
# would append a second copy of it.
MARKER_SHIM='require("monitor-refresh-rate")'
MARKER_MONITORS='require("hypr.monitor-refresh-rate")'
MARKER_BINDINGS='omarchy-monitor-refresh-rate toggle'
MARKER_MENU='trigger.hardware.refresh-rate'

# ---------------------------------------------------------------------------
# 1. The Hyprland shim
# ---------------------------------------------------------------------------

install_shim() {
  local source="$PLUGIN_DIR/install/hypr-shim.lua"

  [[ -f $source ]] || fail "missing $source"

  if [[ -f $SHIM ]] && grep -q "$MARKER_SHIM" "$SHIM"; then
    say "shim already installed"
    return
  fi

  mkdir -p "$HYPR_DIR"
  cp "$source" "$SHIM"
  say "installed $SHIM"
}

# ---------------------------------------------------------------------------
# 2. The wrapper, so the command can be called by name
# ---------------------------------------------------------------------------

install_wrapper() {
  local source="$PLUGIN_DIR/install/command-wrapper"

  [[ -f $source ]] || fail "missing $source"

  # The wrapper is overwritten every run on purpose: it belongs to the
  # plugin, so an update should refresh it.
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
    cat >"$MONITORS_LUA" <<'EOF'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = "auto"

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
EOF
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
    cat >"$BINDINGS_LUA" <<'EOF'
-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.
EOF
    say "created $BINDINGS_LUA"
  fi

  if grep -q "$MARKER_BINDINGS" "$BINDINGS_LUA"; then
    say "bindings.lua already patched"
    return
  fi

  printf '%s\n' "$block" >>"$BINDINGS_LUA"
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
  # ours before the closing brace, with a comma after it, so both the shell's
  # parser and a strict JSON parser are happy.
  python3 - "$MENU_JSONC" "$entry" <<'PY'
import re
import sys

path, entry = sys.argv[1], sys.argv[2]

with open(path, encoding="utf-8") as handle:
    text = handle.read()

# Drop the trailing comma of the last entry so ours can be appended cleanly.
text = re.sub(r",(\s*})\s*$", r"\1", text.rstrip())

# Insert before the final closing brace.
match = re.search(r"}\s*$", text)
if not match:
    sys.exit("setup.sh: could not find the closing brace of the menu file")

text = text[: match.start()].rstrip().rstrip(",")
text = text + ",\n" + entry + "\n}\n"

with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
  say "patched $MENU_JSONC"
}

# ---------------------------------------------------------------------------

echo "Setting up $PLUGIN_ID"

install_shim
install_wrapper
install_monitors_lua
install_bindings_lua
install_menu_entry

echo
echo "Done. Reload Hyprland and the shell for the changes to take effect:"
echo
echo "  hyprctl reload"
echo "  omarchy restart shell"
echo
echo "Then try:  SUPER + SHIFT + R       (cycle the rate)"
echo "            SUPER + SHIFT + ALT + R (open the panel)"
