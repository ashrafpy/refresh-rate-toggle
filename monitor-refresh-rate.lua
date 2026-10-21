-- Applies the refresh rate chosen with omarchy-monitor-refresh-rate.
--
-- The state file holds one "output=mode" or "output=mode,scale" line per
-- display, e.g.
--
--   eDP-1=1920x1080@59.99Hz,1.25
--
-- Each line becomes an hl.monitor() rule, applied after the catch-all rule in
-- monitors.lua so the specific rate and per-display scale win. The rules are
-- built from the file rather than eval'd as Lua, so a malformed state file can
-- only ever produce an invalid mode, never code execution.

local M = {}

local paths = require("default.hypr.paths")

M.state_path = paths.state_home .. "/omarchy/monitor-refresh-rates"
M.toggles_dir = paths.state_home .. "/omarchy/toggles/hypr"

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

-- An optional per-display scale saved alongside the mode.
local function safe_scale(scale)
  if type(scale) ~= "string" or scale == "" then
    return nil
  end
  if not scale:match("^%d+%.?%d*$") then
    return nil
  end
  local num = tonumber(scale)
  if not num or num <= 0 then
    return nil
  end
  return num
end

-- Read the saved rates as a list of { output = ..., mode = ..., scale = ... }.
function M.saved_rates()
  local rates = {}
  local handle = io.open(M.state_path, "r")
  if not handle then
    return rates
  end

  for raw_line in handle:lines() do
    -- Trim the line first: a hand-edited file may pad it with spaces.
    local line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
    local output, rhs = line:match("^([A-Za-z0-9._-]+)%s*=%s*(.+)$")
    output = safe_output(output)
    if output and rhs then
      local clean_rhs = rhs:gsub("%s+", "")
      local raw_mode, raw_scale = clean_rhs:match("^([^,]+),(.+)$")
      if not raw_mode then
        raw_mode = clean_rhs
      end
      local mode = safe_mode(raw_mode)
      local scale = safe_scale(raw_scale)
      if mode then
        table.insert(rates, { output = output, mode = mode, scale = scale })
      end
    end
  end
  handle:close()

  return rates
end

-- Outputs currently disabled by Omarchy's clamshell or manual-disable toggle
-- files in ~/.local/state/omarchy/toggles/hypr/. Applying a mode rule to an
-- output that a toggle file disabled would re-enable the panel while the
-- laptop lid is shut.
local function disabled_outputs()
  local disabled = {}
  local files = {
    M.toggles_dir .. "/internal-monitor-clamshell.lua",
    M.toggles_dir .. "/internal-monitor-disable.lua",
  }

  for _, path in ipairs(files) do
    local handle = io.open(path, "r")
    if handle then
      local content = handle:read("*a") or ""
      handle:close()
      for output in content:gmatch('output%s*=%s*"([A-Za-z0-9._-]+)"') do
        if content:find("disabled%s*=%s*true") then
          disabled[output] = true
        end
      end
    end
  end

  return disabled
end

-- The live scale of each connected display.
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
-- Prefer the display's live scale if it is already active, then the per-display
-- scale saved in the state file, and finally `fallback_scale` from monitors.lua.
function M.apply(fallback_scale)
  local scales = live_scales()
  local disabled = disabled_outputs()

  for _, rate in ipairs(M.saved_rates()) do
    if not disabled[rate.output] then
      hl.monitor({
        output = rate.output,
        mode = rate.mode,
        position = "auto",
        scale = scales[rate.output] or rate.scale or fallback_scale or "auto",
      })
    end
  end
end

-- Watch for a display being plugged in or unplugged, or the config reloading,
-- and re-apply the saved rates for all non-disabled displays.
function M.watch(scale)
  local function reapply()
    M.apply(scale)
  end

  pcall(hl.on, "monitor.added", reapply)
  pcall(hl.on, "monitor.removed", reapply)
  pcall(hl.on, "config.reloaded", reapply)
end

-- Retained as a no-op so existing monitors.lua files that call
-- refresh_rate.heal() continue to work; background drift healing now runs in
-- Service.qml outside Hyprland's Lua state.
function M.heal()
end

return M
