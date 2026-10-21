# Refresh Rate (`refresh-rate-toggle`)

Switch any Hyprland display between the refresh rates it actually supports.

Rates are read directly from each monitor's `availableModes` in Hyprland, so a
144Hz panel is offered 144Hz while a 60Hz-only external monitor is never
offered a rate it cannot reach. Chosen rates are persisted per display and
automatically reapplied across reboots, `hyprctl reload`, scale changes, and
laptop clamshell events.

---

## Quick Reference

### Plugin Lifecycle

| Task | Command |
| :--- | :--- |
| **Install** | `omarchy plugin add https://github.com/ashrafpy/refresh-rate-toggle.git --enable` |
| **Update** | `omarchy plugin update refresh-rate-toggle --yes` |
| **Reinstall** | `omarchy plugin remove refresh-rate-toggle --yes && omarchy plugin add https://github.com/ashrafpy/refresh-rate-toggle.git --enable` |
| **Uninstall** | `~/.config/omarchy/plugins/refresh-rate-toggle/install/setup.sh --uninstall && omarchy plugin remove refresh-rate-toggle --yes` |
| **Local Dev Sync** | `./dev.sh` |

### Keybindings & UI

| Action | Shortcut / Path | Command Executed |
| :--- | :--- | :--- |
| **Cycle focused display's rate** | `SUPER + SHIFT + R` | `omarchy-monitor-refresh-rate toggle` |
| **Toggle Refresh Rate panel** | `SUPER + SHIFT + ALT + R` | `omarchy-shell shell toggle refresh-rate-toggle` |
| **Open panel from Omarchy menu** | Trigger → Hardware → Refresh Rate | `omarchy-shell shell summon refresh-rate-toggle` |

---

## 1. Installation & Lifecycle

### Install

```bash
omarchy plugin add https://github.com/ashrafpy/refresh-rate-toggle.git --enable
```

Passing `--enable` starts `Service.qml` inside `omarchy-shell`, which
automatically runs `install/setup.sh --auto` to wire the Hyprland Lua shim,
keybindings, CLI wrapper, and menu entry, and reloads Hyprland.

> **If you ran `omarchy plugin add` without `--enable`:**
> Run `setup.sh` once to wire the external files, enable the plugin, and
> reload Hyprland:
> ```bash
> ~/.config/omarchy/plugins/refresh-rate-toggle/install/setup.sh
> ```

### Update

```bash
omarchy plugin update refresh-rate-toggle --yes
```

`omarchy plugin update` pulls the latest changes into
`~/.config/omarchy/plugins/refresh-rate-toggle` and reloads the plugin in
`omarchy-shell`. `Service.qml` automatically refreshes the shim and command
wrapper if either changed.

### Reinstall

`omarchy plugin add` refuses to overwrite an already-installed plugin ID, so
remove it first before adding it again:

```bash
omarchy plugin remove refresh-rate-toggle --yes
omarchy plugin add https://github.com/ashrafpy/refresh-rate-toggle.git --enable
```

### Uninstall

Run `setup.sh --uninstall` first to strip the plugin's entries from
`monitors.lua`, `bindings.lua`, and `omarchy-menu.jsonc` and delete the shim
and CLI wrapper, then remove the plugin itself:

```bash
~/.config/omarchy/plugins/refresh-rate-toggle/install/setup.sh --uninstall
omarchy plugin remove refresh-rate-toggle --yes
```

*(Optional)* Remove saved per-display refresh rates:

```bash
rm -f ~/.local/state/omarchy/monitor-refresh-rates
```

---

## 2. Using the Panel & Keybindings

- **`SUPER + SHIFT + R`**: Steps the focused display down to the next
  supported refresh rate (wrapping back to the highest rate after the lowest)
  and sends a desktop notification.
- **`SUPER + SHIFT + ALT + R`** (or **Trigger → Hardware → Refresh Rate**):
  Opens the Refresh Rate overlay panel.
  - Displays each connected monitor and all refresh rates it supports, with
    the active rate highlighted.
  - **`Up` / `Down`**: Select a display.
  - **`Enter`**: Step the selected display to its next refresh rate.
  - **Click a rate chip**: Switch that display directly to the clicked rate.
  - **`Esc` / click outside**: Dismiss the panel.

---

## 3. CLI Reference (`omarchy-monitor-refresh-rate`)

```text
omarchy-monitor-refresh-rate [options] [action]
```

### Common Examples

```bash
# Print the focused display and its current rate (e.g. "eDP-1 144Hz")
omarchy-monitor-refresh-rate

# Print only the bare rounded rate number of the focused display (e.g. "144")
omarchy-monitor-refresh-rate --current

# List all rates offered by the focused display (* marks the active rate)
omarchy-monitor-refresh-rate list

# Cycle the focused display to the next rate down (wraps around to highest)
omarchy-monitor-refresh-rate toggle

# Switch the focused display to a specific rate
omarchy-monitor-refresh-rate 60

# Target a specific display by connector name
omarchy-monitor-refresh-rate --monitor DP-2 list
omarchy-monitor-refresh-rate --monitor DP-2 144
omarchy-monitor-refresh-rate --monitor DP-2 toggle

# Check in scripts whether a display supports a given rate (exit 0 = yes, 1 = no)
omarchy-monitor-refresh-rate --monitor DP-2 --supports 120

# Re-apply saved rates to any display that drifted (preserving current resolution)
omarchy-monitor-refresh-rate --heal
```

### Actions

| Action | Description |
| :--- | :--- |
| *(none)* | Print the target display's name and current rounded rate (e.g. `eDP-1 60Hz`). |
| `toggle` | Switch to the next supported rate down, wrapping around to the highest rate after the lowest. |
| `<rate>` | Switch to a specific refresh rate (e.g. `144`, `60`, or `59.99`). |
| `list` | List all refresh rates the target display supports, with the active rate marked `*`. |

### Options / Flags

| Flag | Description | Exit Code |
| :--- | :--- | :--- |
| `--monitor <name>` | Act on `<name>` instead of the currently focused display. Composes with any action or flag. | `0` on success |
| `--current` | Print the target display's current rate as a bare integer (e.g. `60`). | `0` on success, `1` if not found |
| `--supports <rate>` | Quietly test whether the target display offers `<rate>` (within `0.5Hz` tolerance). | `0` if supported, `1` if not |
| `--list-displays` | Print all active displays as `name<TAB>current<TAB>rate,rate,...` (used by `Service.qml` / `Panel.qml`). | `0` |
| `--drift-check` | Write names of displays that drifted from their saved rate to `~/.local/state/omarchy/monitor-refresh-rate-drift`. | `0` |
| `--heal` | Restore every drifted display to its saved refresh rate while keeping its current resolution and scale (and persist any user-made scale change). | `0` if healed, `1` if no drift |
| `-h`, `--help` | Print usage summary. | `0` |

### Error Messages

| Error Message | Cause |
| :--- | :--- |
| `Missing monitor name for --monitor` | `--monitor` was passed without a connector argument. |
| `Missing rate for --supports` | `--supports` was passed without a rate argument. |
| `Refusing unsafe monitor name` | `--monitor` contained characters outside `A-Z a-z 0-9 . _ -`. |
| `Invalid rate` | `--supports` was passed a non-numeric value. |
| `No monitor found` | No focused monitor was reported by Hyprland. |
| `No active monitor named <name>` | The specified monitor is disconnected or disabled. |
| `No mode found for <rate> Hz on <name>` | The display does not support `<rate>`. Supported rates are printed below the error. |
| `Usage: ...` | An unrecognized action was passed. |

---

## 4. Installer Reference (`install/setup.sh`)

```text
~/.config/omarchy/plugins/refresh-rate-toggle/install/setup.sh [--auto | --uninstall | --help]
```

### `setup.sh` Options

| Option | Description |
| :--- | :--- |
| *(none)* | Install or update all external files, enable the plugin in `omarchy-shell` if needed, and run `hyprctl reload` if any Hyprland config file changed. |
| `--auto` | Quietly verify and repair external files, calling `hyprctl reload` only if a Hyprland file changed. Invoked automatically by `Service.qml`. |
| `--uninstall` | Remove the shim and command wrapper, strip the plugin's blocks from `monitors.lua`, `bindings.lua`, and `omarchy-menu.jsonc`, and reload Hyprland. |
| `-h`, `--help` | Print installer usage summary. |

### External Files Managed by `setup.sh`

Because Hyprland's Lua runtime and the user's `PATH` do not automatically look
inside `~/.config/omarchy/plugins/`, `setup.sh` manages five external items:

| Path | Role |
| :--- | :--- |
| `~/.config/hypr/monitor-refresh-rate.lua` | Shim that locates this plugin via `manifest.json`, adds it to Hyprland's Lua `package.path`, and loads `monitor-refresh-rate.lua`. |
| `~/.config/hypr/monitors.lua` | Appends `refresh_rate.apply()`, `refresh_rate.watch()`, and `refresh_rate.heal()` after Omarchy's catch-all monitor rule. |
| `~/.config/hypr/bindings.lua` | Adds the `SUPER + SHIFT + R` and `SUPER + SHIFT + ALT + R` keybindings. |
| `~/.local/bin/omarchy-monitor-refresh-rate` | Wrapper script on `PATH` that locates the plugin directory and `exec`s the bundled `omarchy-monitor-refresh-rate`. |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | Adds `trigger.hardware.refresh-rate` (**Trigger → Hardware → Refresh Rate**). |

---

## 5. Local Development (`./dev.sh`)

When editing this repository locally (e.g. in `~/Projects/refresh-rate-toggle`),
use `./dev.sh` to test changes live before pushing to GitHub:

```bash
# 1. Validate, sync working tree to ~/.config/omarchy/plugins/refresh-rate-toggle,
#    run setup.sh, and reload Hyprland + omarchy-shell plugins:
./dev.sh

# 2. Once satisfied, commit and push to GitHub:
git add -A && git commit -m "Describe change" && git push

# 3. Pull the pushed commit cleanly via Omarchy's plugin updater:
omarchy plugin update refresh-rate-toggle --yes
```

What `./dev.sh` does:
1. Validates the checkout with `omarchy-plugin-validate`.
2. Aligns the installed plugin clone's git `HEAD` with your repo's `HEAD` so
   `omarchy plugin update` stays fast-forwardable once edits are committed.
3. Syncs working-tree files (including uncommitted changes) into
   `~/.config/omarchy/plugins/refresh-rate-toggle`.
4. Runs `setup.sh`, `hyprctl reload`, and `omarchy-shell shell rescanPlugins`.

---

## 6. Architecture & How It Works

### State File

Chosen refresh rates and per-display scales are stored in
`~/.local/state/omarchy/monitor-refresh-rates` as one `output=mode,scale` line
per display (with backwards compatibility for `output=mode`):

```ini
eDP-1=1920x1080@59.99Hz,1.25
DP-2=2560x1440@144.00Hz,1
```

When switching rates (`commit_rate`), the state file is written **before**
`hyprctl eval` applies the mode so the heal loop can never observe a live rate
change ahead of the state file and undo it. If `hyprctl eval` fails, the state
file is rolled back to its previous contents.

### Runtime Components

1. **[`monitor-refresh-rate.lua`](monitor-refresh-rate.lua) (Hyprland Lua)**
   - `apply(fallback_scale)`: Reads `~/.local/state/omarchy/monitor-refresh-rates`,
     validates connector names, mode strings, and per-display scales (never
     evaluating the file as code), skips any output currently disabled by
     Omarchy's clamshell/manual-disable toggles in
     `~/.local/state/omarchy/toggles/hypr/`, and emits `hl.monitor()` rules
     after Omarchy's catch-all rule in `monitors.lua`.
   - `watch(scale)`: Re-applies saved rules for enabled displays on
     `monitor.added`, `monitor.removed`, and `config.reloaded`.
2. **[`Service.qml`](Service.qml) (Quickshell Background Service)**
   - Runs `install/setup.sh --auto` on startup and plugin reload.
   - Keeps `displays` warm in memory and watches the state file via `FileView`
     so CLI/keybind changes update the UI model without background polling.
   - Listens to `Hyprland.onRawEvent` (`monitoradded`, `monitorremoved`,
     `configreloaded`) and runs both event-driven follow-up heals (`1.2s`,
     `3.5s`, `7.5s`) and a `5s` periodic `--heal` check outside Hyprland's Lua
     state.
3. **[`Panel.qml`](Panel.qml) (Quickshell Overlay UI)**
   - Reads the warm display list from `Service.qml` on open so displays render
     on the first frame, and delegates rate changes to `Service.qml`.

---

## 7. Technical Notes

1. **Per-display scale preservation**
   - Omarchy's stock `monitors.lua` uses a catch-all rule
     (`hl.monitor({ output = "", scale = omarchy_monitor_scale })`). To prevent
     reloads or reboots from flattening differently scaled displays to one
     scale, this plugin saves each display's scale alongside its mode in
     `~/.local/state/omarchy/monitor-refresh-rates` and updates it when you
     change a display's scale.
2. **Clamshell & manual-disable compatibility**
   - `monitor-refresh-rate.lua` checks
     `~/.local/state/omarchy/toggles/hypr/internal-monitor-clamshell.lua` and
     `internal-monitor-disable.lua` before applying rules so a `config.reloaded`
     or hotplug event never re-enables a closed laptop panel while docked. When
     the lid is reopened and `omarchy-hyprland-monitor-clamshell` resets the
     panel to `mode = "preferred"`, `Service.qml` restores the saved refresh
     rate automatically.
3. **Resolution preservation & NTSC sibling deduplication**
   - Switching rates (`toggle` or `<rate>`) and healing (`--heal`) always prefer
     a mode matching the display's *current* resolution so changing refresh
     rates never rescales your desktop.
   - Displays that advertise both nominal and fractional NTSC sibling timings
     (such as `60.00Hz` and `59.94Hz`, or `120.00Hz` and `119.88Hz`) are
     deduplicated by rounded whole-number Hz (preferring the largest resolution
     and highest nominal rate), preventing duplicate `"60 Hz"` chips in the
     panel and ensuring `toggle` steps cleanly through distinct rates.
   - To stop the plugin from managing a display, delete its line from
     `~/.local/state/omarchy/monitor-refresh-rates` (or run
     `setup.sh --uninstall`).
4. **Keep `local omarchy_monitor_scale = ...` in `monitors.lua`**
   - `omarchy-hyprland-monitor-scaling` rewrites that exact line in place to
     persist default scale changes. `setup.sh` only appends to `monitors.lua`
     and never modifies that line.
