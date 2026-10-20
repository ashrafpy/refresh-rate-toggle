# Refresh Rate

Switch a display between the refresh rates it actually supports.

Works on any display Hyprland knows about: the rates come from the monitor's
own `availableModes`, so a 144Hz panel is offered 144Hz and a 60Hz-only
external monitor is not offered a rate it cannot reach.

## Install

```bash
omarchy plugin add https://github.com/ashrafpy/refresh-rate-toggle.git
~/.config/omarchy/plugins/refresh-rate-toggle/install/setup.sh
hyprctl reload && omarchy restart shell
```

`omarchy plugin add` clones the plugin, but it cannot wire the plugin into
Hyprland: the shell plugin system and the Hyprland config are separate
systems, and nothing bridges them for third-party plugins. The `setup.sh`
script does that part — it installs the Hyprland shim, the keybindings, the
command wrapper, and the menu entry. It is idempotent, so running it again
changes nothing.

### Reinstalling

`omarchy plugin add` refuses to overwrite a plugin whose id is already
installed:

```
omarchy-plugin-add: plugin 'refresh-rate-toggle' is already installed;
update it with: omarchy plugin update refresh-rate-toggle
```

So to install again — after a fresh clone, or to move to a new machine —
remove it first:

```bash
omarchy plugin remove refresh-rate-toggle --yes
omarchy plugin add https://github.com/ashrafpy/refresh-rate-toggle.git
~/.config/omarchy/plugins/refresh-rate-toggle/install/setup.sh
```

`omarchy plugin remove` deletes the plugin directory and takes the plugin
out of `shell.json`. It does not touch the four files `setup.sh` installs
outside it, and `setup.sh` overwrites them anyway, so a reinstall leaves no
trace of the previous one.

### Updating

`omarchy plugin update` pulls into the installed clone, so it is the copy in
`~/.config/omarchy/plugins/` that gets updated, not your checkout:

```bash
omarchy plugin update refresh-rate-toggle --yes
~/.config/omarchy/plugins/refresh-rate-toggle/install/setup.sh
```

Run `setup.sh` again afterwards. It refreshes the files it owns — the
wrapper in particular — and leaves the rest of your config alone.

## Using it

| What | How |
|------|-----|
| Cycle the focused display's rate | `SUPER + SHIFT + R` |
| Open the panel (picks a rate per display) | `SUPER + SHIFT + ALT + R` |
| Same, from the menu | Trigger → Hardware → Refresh Rate |

The panel lists every display and the rates it offers, with the running rate
marked. Enter switches to the next rate; clicking a rate picks it directly.

The rate is saved per display and reapplied on every Hyprland reload, so it
survives a reboot, a `hyprctl reload`, and a change of scale.

## The command

`omarchy-monitor-refresh-rate` is the command half. With no arguments it
reports the focused display's rate.

```
omarchy-monitor-refresh-rate [options] [action]
```

### Actions

| Action | What it does |
|--------|--------------|
| *(none)* | Print the focused display's rate, e.g. `eDP-1 60Hz` |
| `toggle` | Switch to the next rate down, wrapping round to the highest at the bottom |
| `<rate>` | Switch to that rate, e.g. `144` or `59.99` |
| `list` | List the rates the display offers, with the running one marked `*` |

### Flags

| Flag | What it does | Exit code |
|------|--------------|-----------|
| `--monitor <name>` | Act on that display instead of the focused one. Used with any action | 0 on success |
| `--supports <rate>` | Report whether the display offers that rate. Prints nothing | 0 if it does, 1 if it does not |
| `--current` | Print the display's rate as a bare number, e.g. `60` | 0 on success, 1 if the display is not there |
| `--list-displays` | Print every display as `name<TAB>rate<TAB>rate,rate,...` — the format the panel reads | 0 on success |
| `--drift-check` | Report displays that left their saved rate, by writing their names to `~/.local/state/omarchy/monitor-refresh-rate-drift`. Prints nothing | 0 always |
| `--heal` | Put every display back on the rate saved for it, at the resolution it is running now | 0 if something was healed, 1 if nothing had drifted |
| `-h`, `--help` | Print the usage summary | 0 |

The flags compose with the actions: `--monitor DP-2 --current` prints
`DP-2`'s rate, and `--monitor DP-2 144` switches `DP-2` to 144Hz.

### Errors

| Message | Cause |
|---------|-------|
| `Refusing unsafe monitor name` | The name is not a plain connector name. Only `A-Z a-z 0-9 . _ -` pass |
| `Invalid rate` | `--supports` was given something that is not a number |
| `No monitor found` | There is no focused display to act on |
| `No mode found for <rate> Hz on <name>` | The display does not offer that rate. The rates it does offer are listed underneath |
| `Usage: ...` | The action was not one of the ones above |

## How it works

The chosen rate is written to `~/.local/state/omarchy/monitor-refresh-rates`
as one `output=mode` line per display:

```
eDP-1=1920x1080@59.99Hz
```

`monitor-refresh-rate.lua` turns each line into a monitor rule and applies it
after Omarchy's catch-all rule, so the specific rate wins. The rules are
built from the file's contents rather than evaluated as code, so a malformed
line can only ever produce an invalid mode, never code execution.

Because the state is a file, the rate survives a reboot, a `hyprctl reload`,
and a change of scale.

### Files outside this directory

`setup.sh` installs four small files outside the plugin, because Hyprland and
the shell cannot reach into a plugin directory on their own:

- `~/.config/hypr/monitor-refresh-rate.lua` — a shim that puts this plugin's
  directory on Hyprland's Lua `package.path` and requires the module here.
- `~/.config/hypr/monitors.lua` — the calls into the plugin: `apply()`,
  `watch()` and `heal()`. They have to run *after* Omarchy's catch-all rule,
  which would otherwise claim the display and hand it back its preferred mode.
- `~/.config/hypr/bindings.lua` — the two keybindings.
- `~/.local/bin/omarchy-monitor-refresh-rate` — a wrapper that finds this
  plugin and runs the command, so it can be called by name.

The script also adds a row to the Omarchy menu, under Trigger → Hardware.

It does not remove anything. To uninstall:

```bash
omarchy plugin remove refresh-rate-toggle --yes
rm ~/.config/hypr/monitor-refresh-rate.lua
rm ~/.local/bin/omarchy-monitor-refresh-rate
```

Then remove the plugin's block from `~/.config/hypr/monitors.lua`, its two
`o.bind` lines from `~/.config/hypr/bindings.lua`, and its row from
`~/.config/omarchy/extensions/omarchy-menu.jsonc`. Each is marked with
`refresh-rate-toggle` or the plugin's own calls, so they are easy to find.

The saved rates in `~/.local/state/omarchy/monitor-refresh-rates` are left
behind. Delete that file to forget them.

## Known issues

**Omarchy's catch-all rule flattens every display to one scale.**
`monitors.lua` sets `hl.monitor({ output = "", scale = ... })` for all
displays, so on reload a display you had scaled differently goes back to the
catch-all's scale. This is Omarchy's behaviour, not this plugin's — it
reproduces with the plugin's rules removed. The plugin never changes a
display's scale; it only carries the scale a display already has into the
rule it writes.

**Do not remove the `local omarchy_monitor_scale = ` line from `monitors.lua`.**
`omarchy-hyprland-monitor-scaling` rewrites that exact line in place to
persist a scale change, and stops persisting scales if the line is gone or
renamed. The plugin's installer appends to the file and never touches it.

**Omarchy's clamshell handling resets the internal display to its preferred
mode.** `omarchy-hyprland-monitor-clamshell` re-enables the internal display
with `mode = "preferred"`, which hands the panel back its fastest rate and
leaves the saved rate behind in the state file. The plugin's `heal()` loop
watches for this and puts the rate back, usually within a few seconds. Until
it was added, a `hyprctl reload` was the only way to undo it.

**A resolution change is not undone, but a rate change is.** The heal loop
compares the *rate* a display is running against the rate saved for it, so
changing the resolution by hand sticks, and so does a scale change made at
the same time. Changing the rate by hand does not: the display is put back
on the saved rate within a few seconds. Delete the display's line from the
state file to stop the plugin managing it.

**The state file and the running display can disagree for a moment.** The
rate is written to the state file *before* it is applied to the display, so
that the heal loop can never race a change and undo it. The trade-off is
that if the apply then fails, the state file records a rate the display never
reached. A reload puts the display back on the recorded rate.

**Hyprland's Lua cannot read the live refresh rate.** `hl.get_monitors()`
reports the name, description, resolution, scale and position of each
display, but not its refresh rate or current mode. The drift check therefore
runs as a separate process rather than in Lua.

**`hyprctl` deadlocks when called from inside Hyprland's Lua.** A
`hyprctl` call made from Hyprland's own Lua goes to the very process that is
waiting on it, and comes back as `Hyprland IPC didn't respond in time`. The
plugin works around this by spawning the check with `hl.exec_cmd`, which
runs outside the compositor's blocked thread. The same applies to
`io.popen("hyprctl ...")`, which fails the same way.

**A timer that is not self-rearming never fires.** Hyprland's `hl.timer` with
`{ running = true }` never ticks. The heal loop uses a one-shot timer that
re-arms itself after each tick, the pattern Omarchy's own clipboard timer
uses.

**The panel polls while it is open.** The panel refreshes its display list
every five seconds, so it shows a rate change made elsewhere. It does not
poll while closed.
