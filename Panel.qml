import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Refresh rate panel.
//
// Lists the refresh rates each connected display actually offers (read from
// the compositor's own availableModes, so a display that cannot do 144Hz is
// never offered it) and switches a display to the rate you pick.
//
// The choice is written to ~/.local/state/omarchy/monitor-refresh-rates and
// reapplied on every Hyprland reload by the companion Lua module, so it
// survives a reboot.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property var displays: []   // [{ name, rate, rates: [rate, ...] }]
  property int selectedIndex: 0
  property bool cursorActive: false

  // The plugin's own directory, so the bundled script is found no matter
  // where the plugin was installed.
  readonly property string pluginDir: manifest && manifest.__sourceDir ? manifest.__sourceDir : ""
  readonly property string fontFamily: Style.font.family

  function scriptPath() {
    return root.pluginDir + "/omarchy-monitor-refresh-rate"
  }

  // ---- data ----

  function refresh() {
    if (root.pluginDir === "") return
    if (listProc.running) return
    listProc.command = [root.scriptPath(), "--list-displays"]
    listProc.running = true
  }

  // Parse the script's tab-delimited output into the display model. Each line
  // is: name, current rate, then a comma-separated list of offered rates.
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
    if (root.selectedIndex >= parsed.length) root.selectedIndex = Math.max(0, parsed.length - 1)
  }

  // ---- actions ----

  function setRate(displayName, rate) {
    if (setProc.running) return
    setProc.command = [root.scriptPath(), "--monitor", displayName, String(rate)]
    setProc.running = true
  }

  function currentDisplay() {
    if (root.displays.length === 0) return null
    var index = Math.max(0, Math.min(root.selectedIndex, root.displays.length - 1))
    return root.displays[index]
  }

  // The rate the display should move to: the next one it offers, wrapping at
  // the end.
  function nextRate(display) {
    var rates = display.rates
    if (!rates || rates.length === 0) return null

    var currentIndex = -1
    for (var i = 0; i < rates.length; i++) {
      if (Math.abs(rates[i] - display.rate) < 0.5) { currentIndex = i; break }
    }

    if (currentIndex === -1 || currentIndex >= rates.length - 1) return rates[0]
    return rates[currentIndex + 1]
  }

  function activateCursor() {
    var display = root.currentDisplay()
    if (!display) return

    var next = root.nextRate(display)
    if (next === null) return

    root.setRate(display.name, next)
  }

  function moveCursor(dy) {
    if (root.displays.length === 0) return
    var next = root.selectedIndex + dy
    if (next < 0) next = 0
    if (next > root.displays.length - 1) next = root.displays.length - 1
    root.selectedIndex = next
  }

  // ---- lifecycle ----

  function open(payloadJson) {
    root.opened = true
    root.refresh()
    // The window is instantiated hidden, so the content's `focus: true` is
    // evaluated before the surface is mapped and Escape would land nowhere.
    // Re-acquire after mapping.
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    root.cursorActive = false
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "refresh-rate-toggle")
    else close()
  }

  // ---- processes ----

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseDisplays(text)
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector { waitForEnd: true }
    // The script applies the rate and saves it; re-read the list so the
    // panel shows the rate that is now running.
    onRunningChanged: if (!running) root.refresh()
  }

  Timer {
    id: pollTimer
    interval: 5000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  // The host assigns the manifest after the item is constructed, so the
  // bundled script's path only becomes known then.
  onManifestChanged: if (manifest) root.refresh()

  // ---- overlay ----

  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "refresh-rate-toggle"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    // A scrim carries the contrast on any wallpaper, so the card reads the
    // same over a light one.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.6)

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.dismiss()
      Keys.onReturnPressed: root.activateCursor()
      Keys.onEnterPressed: root.activateCursor()
      Keys.onUpPressed: {
        root.cursorActive = true
        root.moveCursor(-1)
      }
      Keys.onDownPressed: {
        root.cursorActive = true
        root.moveCursor(1)
      }

      // The card itself, centered.
      BorderSurface {
        id: card
        anchors.centerIn: parent
        width: Math.min(Style.space(400), keyCatcher.width - Style.space(64))
        height: cardColumn.implicitHeight + Style.space(48)
        radius: Style.cornerRadius
        color: Commons.Color.popups.background
        borderSpec: Border.localOrSurfaceSpec("popups", "border", Commons.Color.popups.border, Commons.Color.popups.border, Math.max(1, Style.space(2)))

        Column {
          id: cardColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(24)
          spacing: Style.space(14)

          Row {
            spacing: Style.space(14)

            Text {
              text: "󰍹"
              color: Commons.Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                text: "Refresh Rate"
                color: Commons.Color.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                text: root.displays.length > 0
                      ? "Enter switches the display's rate"
                      : "No display reports a selectable refresh rate"
                color: Commons.Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Commons.Color.popups.border
          }

          Text {
            text: "DISPLAYS"
            color: Commons.Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Repeater {
            model: root.displays

            Rectangle {
              id: row
              required property var modelData
              required property int index

              readonly property bool isCursor: root.cursorActive && root.selectedIndex === index

              width: cardColumn.width
              height: rowColumn.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: isCursor
                     ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
                     : "transparent"

              // Behind the rate chips below, so a click on a chip reaches the
              // chip rather than falling through to the row's own handler.
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
                onClicked: {
                  root.selectedIndex = row.index
                  root.cursorActive = true
                  root.activateCursor()
                }
              }

              Column {
                id: rowColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                RowLayout {
                  width: parent.width
                  spacing: Style.space(12)

                  Text {
                    text: row.modelData.name
                    color: Commons.Color.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }

                  Text {
                    text: Math.round(row.modelData.rate) + " Hz"
                    color: Commons.Color.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                // Every rate the display offers, with the running one marked.
                Row {
                  spacing: Style.space(6)

                  Repeater {
                    model: row.modelData.rates

                    Rectangle {
                      required property var modelData
                      readonly property bool isCurrent: Math.abs(modelData - row.modelData.rate) < 0.5

                      width: rateText.implicitWidth + Style.space(16)
                      height: rateText.implicitHeight + Style.space(8)
                      radius: Style.cornerRadius
                      color: isCurrent
                             ? Commons.Color.accent
                             : "transparent"
                      border.width: isCurrent ? 0 : Math.max(1, Style.space(1))
                      border.color: Commons.Color.popups.border

                      Text {
                        id: rateText
                        anchors.centerIn: parent
                        text: Math.round(parent.modelData) + " Hz"
                        color: parent.isCurrent
                               ? Commons.Color.background
                               : Commons.Color.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.selectedIndex = row.index
                          root.cursorActive = true
                          root.setRate(row.modelData.name, parent.modelData)
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
