-- Applies the refresh rate chosen with omarchy-monitor-refresh-rate.
--
-- The state file holds one "output=mode" line per display, e.g.
--
--   eDP-1=1920x1080@59.99Hz
--
-- Each line becomes an hl.monitor() rule, applied after the catch-all rule in
-- monitors.lua so the specific rate wins. The rules are built from the file
-- rather than eval'd as Lua, so a malformed state file can only ever produce an
-- invalid mode, never code execution.

local M = {}

local paths = require("default.hypr.paths")

M.state_path = paths.state_home .. "/omarchy/monitor-refresh-rates"

-- A connector name is used as a Lua string literal, so it must not be able to
-- close that string.
local function safe_output(name)
  if type(name) ~= "string" or not name:match("^[A-Za-z0-9._-]+$") then
    return nil
  end
  return name
end

-- A mode is "WIDTHxHEIGHT@RATE", the form Hyprland expects.
local function safe_mode(mode)
  if type(mode) ~= "string" then
    return nil
  end
  if not mode:match("^[0-9]+x[0-9]+@%d+%.?%d*[A-Za-z]*$") then
    return nil
  end
  return mode
end

-- Read the saved rates as a list of { output = ..., mode = ... } pairs.
function M.saved_rates()
  local rates = {}
  local handle = io.open(M.state_path, "r")
  if not handle then
    return rates
  end

  for raw_line in handle:lines() do
    -- Trim the line first: a hand-edited file may pad it with spaces.
    local line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
    local output, mode = line:match("^([A-Za-z0-9._-]+)%s*=%s*(.+)$")
    output = safe_output(output)
    mode = safe_mode(mode and (mode:gsub("%s+", "")))
    if output and mode then
      table.insert(rates, { output = output, mode = mode })
    end
  end
  handle:close()

  return rates
end

-- The live scale of each display, so a rule for one display does not drag
-- another display's scale to the same value.
--
-- A monitor rule without a scale makes Hyprland fall back to its own default
-- scale, so every rule here states the scale the display is already running.
local function live_scales()
  local scales = {}
  local ok, monitors = pcall(hl.get_monitors)
  if not ok or type(monitors) ~= "table" then
    return scales
  end

  for _, monitor in ipairs(monitors) do
    local name, scale
    if pcall(function()
      name = monitor.name
      scale = monitor.scale
    end) then
      if type(name) == "string" and type(scale) == "number" then
        scales[name] = scale
      end
    end
  end

  return scales
end

-- Apply the saved rates.
--
-- `fallback_scale` is the scale the catch-all rule in monitors.lua set. It is
-- only used for a display that is not currently connected, since a live
-- display's own scale is always the better answer.
function M.apply(fallback_scale)
  local scales = live_scales()

  for _, rate in ipairs(M.saved_rates()) do
    hl.monitor({
      output = rate.output,
      mode = rate.mode,
      position = "auto",
      scale = scales[rate.output] or fallback_scale or "auto",
    })
  end
end

-- Watch for a display being plugged in or unplugged and re-apply the saved
-- rates afterwards.
--
-- Hyprland hands a display back its preferred mode when a monitor rule
-- matches it without a mode, and Omarchy's own clamshell handling does
-- exactly that when it re-enables the internal display. Re-applying the
-- saved rate after the event puts the display back where the user left it,
-- instead of leaving it at the preferred rate until the next reload.
function M.watch(scale)
  local function reapply()
    M.apply(scale)
  end

  pcall(hl.on, "monitor.added", reapply)
  pcall(hl.on, "monitor.removed", reapply)
  pcall(hl.on, "config.reloaded", reapply)
end

-- Whether a display is running the mode saved for it.
--
-- The saved mode is "WIDTHxHEIGHT@RATE". Hyprland's Lua does not expose the
-- live refresh rate on a monitor object, and hyprctl cannot be called from
-- inside the compositor's own Lua: the request goes to the very process
-- waiting on it and times out. The check is therefore run as a separate
-- process, spawned with hl.exec_cmd, which sits outside that wait.
--
-- The helper writes a marker file naming the displays that drifted; the Lua
-- side reads it back.
local DRIFT_FILE = paths.state_home .. "/omarchy/monitor-refresh-rate-drift"

local function helper_command(flag)
  local helper = M.helper_path
  if not helper then
    return nil
  end

  return "sh -c '" .. helper:gsub("'", "'\\''") .. " " .. flag .. " >/dev/null 2>&1'"
end

local function spawn_drift_check()
  local command = helper_command("--drift-check")
  if not command then
    return
  end

  hl.exec_cmd(command)
end

-- Put the display back on its saved rate. This is done by the helper, not by
-- the rule here, because the helper can read the display's available modes
-- and pick the one at the resolution it is running now. A rule built here
-- would pin the resolution as well, and undo a resolution change the user
-- made on purpose.
local function spawn_heal()
  local command = helper_command("--heal")
  if not command then
    return
  end

  hl.exec_cmd(command)
end

-- Read the drift report the helper wrote, and clear it.
local function read_drift()
  local handle = io.open(DRIFT_FILE, "r")
  if not handle then
    return {}
  end

  local drifted = {}
  for raw_line in handle:lines() do
    local line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      table.insert(drifted, line)
    end
  end
  handle:close()

  os.remove(DRIFT_FILE)

  return drifted
end

-- Put a display back on its saved rate if something moved it.
--
-- Omarchy's clamshell handling re-enables the internal display with
-- mode = "preferred", which hands the panel back its fastest rate and leaves
-- the saved rate behind in the state file. Its reconciliation poll runs every
-- couple of seconds while a laptop is docked, so the display can drift away
-- from the saved rate and stay there. A reload heals it, but waiting for one
-- is not a fix.
--
-- The check is a poll rather than an event because the drift happens through
-- a plain mode change, which fires no monitor event.
--
-- The scale is not needed here: the helper reads the live scale of the
-- display it is putting back, so a scale change made in the meantime is
-- kept.
function M.heal()
  local armed = false

  local function arm()
    if armed then
      return
    end
    armed = true

    _G.omarchy_refresh_rate_heal = hl.timer(function()
      armed = false
      spawn_drift_check()

      -- The helper is a separate process, so give it a moment to write its
      -- report before looking for it.
      _G.omarchy_refresh_rate_read = hl.timer(function()
        if #read_drift() > 0 then
          spawn_heal()
        end
        arm()
      end, { interval = 300, timeout = 300, type = "oneshot" })
    end, { interval = 5000, timeout = 5000, type = "oneshot" })
  end

  arm()
end

return M
