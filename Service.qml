import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Background service for the refresh-rate-toggle plugin.
//
// Runs for the lifetime of omarchy-shell while the plugin is enabled:
//   1. Ensures install/setup.sh has wired the Hyprland shim, command wrapper,
//      keybindings, and menu entry whenever the plugin is added or updated.
//   2. Keeps the display model warm so the panel opens with current data on
//      its first frame, and refreshes immediately when the state file changes.
//   3. Watches Hyprland monitor/reload events and runs follow-up heals after
//      Omarchy's clamshell reconciliation window (1s, 3s, 7s).
Item {
  id: root

  property var shell: null
  property var manifest: null

  property var displays: []   // [{ name, rate, rates: [rate, ...] }]
  property int followUpStep: 0
  property bool refreshPending: false
  property bool hasPendingSet: false
  property string pendingDisplayName: ""
  property real pendingRate: 0

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")
  readonly property string stateFilePath: stateHome + "/omarchy/monitor-refresh-rates"
  readonly property string pluginDir: manifest && manifest.__sourceDir ? manifest.__sourceDir : ""

  readonly property var followUpDelays: [1200, 2300, 4000]

  function scriptPath() {
    return root.pluginDir ? (root.pluginDir + "/omarchy-monitor-refresh-rate") : ""
  }

  function setupPath() {
    return root.pluginDir ? (root.pluginDir + "/install/setup.sh") : ""
  }

  function ensureSetup() {
    if (!root.pluginDir || setupProc.running) return
    setupProc.command = [root.setupPath(), "--auto"]
    setupProc.running = true
  }

  function refresh() {
    if (!root.pluginDir) return
    if (listProc.running) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    listProc.command = [root.scriptPath(), "--list-displays"]
    listProc.running = true
  }

  function heal() {
    if (!root.pluginDir || healProc.running) return
    healProc.command = [root.scriptPath(), "--heal"]
    healProc.running = true
  }

  function scheduleFollowUpHeals() {
    root.followUpStep = 0
    followUpTimer.interval = root.followUpDelays[0]
    followUpTimer.restart()
  }

  function applyOptimisticRate(displayName, rate) {
    var rounded = Math.round(Number(rate))
    if (isNaN(rounded)) return
    var next = []
    for (var i = 0; i < root.displays.length; i++) {
      var d = root.displays[i]
      if (d.name === displayName) {
        next.push({ name: d.name, rate: rounded, rates: d.rates })
      } else {
        next.push(d)
      }
    }
    root.displays = next
  }

  function setRate(displayName, rate) {
    if (!root.pluginDir) return false
    root.applyOptimisticRate(String(displayName), rate)
    if (setProc.running) {
      root.pendingDisplayName = String(displayName)
      root.pendingRate = Number(rate)
      root.hasPendingSet = true
      return true
    }
    setProc.command = [root.scriptPath(), "--monitor", String(displayName), String(rate)]
    setProc.running = true
    return true
  }

  function parseDisplays(raw) {
    var parsed = []
    var lines = String(raw || "").split("\n")

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length < 2) continue

      var name = parts[0]
      var current = parseFloat(parts[1])
      if (isNaN(current)) continue

      var rates = []
      if (parts.length > 2 && parts[2] !== "") {
        var offered = parts[2].split(",")
        for (var j = 0; j < offered.length; j++) {
          var rate = parseFloat(offered[j])
          if (!isNaN(rate)) rates.push(rate)
        }
      }

      parsed.push({ name: name, rate: current, rates: rates })
    }

    root.displays = parsed
  }

  onManifestChanged: {
    if (!manifest) return
    root.ensureSetup()
    root.refresh()
  }

  // Watch the state file so CLI / keybinding changes update the cached model
  // without background polling. The state file is written right before
  // `hyprctl eval` applies the new mode, so wait a beat for Hyprland to
  // finish applying the mode before querying `--list-displays`.
  FileView {
    id: stateWatcher
    path: root.stateFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload()
      stateRefreshTimer.restart()
    }
  }

  Timer {
    id: stateRefreshTimer
    interval: 150
    repeat: false
    onTriggered: root.refresh()
  }

  // React to Hyprland monitor hotplug and config reloads, plus schedule
  // follow-up heals right after Omarchy's 1s / 3s / 7s clamshell checks.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name.indexOf("monitoradded") === 0
          || name.indexOf("monitorremoved") === 0
          || name === "configreloaded") {
        root.heal()
        root.refresh()
        root.scheduleFollowUpHeals()
      }
    }
  }

  Timer {
    id: followUpTimer
    repeat: false
    onTriggered: {
      root.heal()
      root.refresh()
      root.followUpStep++
      if (root.followUpStep < root.followUpDelays.length) {
        followUpTimer.interval = root.followUpDelays[root.followUpStep]
        followUpTimer.restart()
      }
    }
  }

  Timer {
    id: periodicHealTimer
    interval: 5000
    repeat: true
    running: root.pluginDir !== ""
    onTriggered: root.heal()
  }

  Process {
    id: setupProc
    onExited: {
      root.heal()
      root.refresh()
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseDisplays(text)
    }
    onExited: {
      if (root.refreshPending) {
        root.refreshPending = false
        root.refresh()
      }
    }
  }

  Process {
    id: healProc
    onExited: function(exitCode) {
      // Exit code 0 means at least one drifted display was healed.
      if (exitCode === 0) root.refresh()
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.hasPendingSet) {
        var nextDisplay = root.pendingDisplayName
        var nextRate = root.pendingRate
        root.hasPendingSet = false
        setProc.command = [root.scriptPath(), "--monitor", nextDisplay, String(nextRate)]
        setProc.running = true
        return
      }
      root.refresh()
    }
  }
}
