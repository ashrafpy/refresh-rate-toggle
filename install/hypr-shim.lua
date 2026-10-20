-- Bridge to the refresh-rate-toggle plugin's Lua module.
--
-- The module itself lives in the plugin directory, so the plugin owns it and
-- it updates with the plugin. Hyprland's Lua can only require() from its own
-- package.path, so this file puts the plugin directory on that path and then
-- requires the module from there.
--
-- If the plugin is not installed, this is a no-op and the display keeps
-- whatever rate Hyprland gives it.

local paths = require("default.hypr.paths")

local PLUGIN_ID = "refresh-rate-toggle"

-- The plugin directory, found by looking for the plugin whose manifest
-- declares this id. The plugin id is normally the directory name too, but
-- matching on the manifest keeps this working if the directory is renamed.
local function plugin_dir()
  local root = paths.config_home .. "/omarchy/plugins"

  local pipe = io.popen(
    "for d in " .. root .. "/*/; do "
      .. "if [ -f \"$d/manifest.json\" ] && grep -q '\"id\"[[:space:]]*:[[:space:]]*\"" .. PLUGIN_ID .. "\"' \"$d/manifest.json\"; then "
      .. "printf '%s' \"${d%/}\"; break; fi; done 2>/dev/null"
  )
  if not pipe then
    return nil
  end

  local dir = pipe:read("*a")
  pipe:close()

  if dir == nil or dir == "" then
    return nil
  end
  return dir
end

local dir = plugin_dir()
if dir then
  package.path = dir .. "/?.lua;" .. package.path
  local module = require("monitor-refresh-rate")

  -- The drift check runs as a separate process, because hyprctl cannot be
  -- called from inside the compositor's own Lua. The module needs to know
  -- where the helper command is to be able to spawn it.
  module.helper_path = dir .. "/omarchy-monitor-refresh-rate"

  return module
end

-- The plugin is not installed: hand back an inert module so the caller does
-- not have to guard the call.
return {
  state_path = paths.state_home .. "/omarchy/monitor-refresh-rates",
  saved_rates = function() return {} end,
  apply = function() end,
  watch = function() end,
  heal = function() end,
}
