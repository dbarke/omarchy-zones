import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "layouts.js" as Layouts

// Snap the active window into a zone of its monitor.
//
// Opening reads the active window, its monitor and the gap/border options
// from hyprctl in one go, asks layouts.js which layouts suit that monitor
// (an ultrawide gets thirds first, a laptop panel only halves), and draws the
// selected layout's zones at real size over the monitor. Picking a zone
// floats the window and moves it there; nothing is tiled or remembered by
// Hyprland itself, so Super+T puts the window back into the layout.
//
// The last layout used on each monitor (by description, so it survives
// reconnects under a new connector name) is preselected next time.
Item {
  id: root

  property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/zones.json"
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string error: ""
  property var win: null          // hyprctl activewindow
  property var mon: null          // hyprctl monitors entry the window is on
  property var area: null         // Layouts.area(mon, ...)
  property var suggestion: null   // Layouts.suggest(area)
  property var layouts: suggestion ? suggestion.layouts : []
  property int layoutIndex: 0
  property var layout: layouts.length ? layouts[Math.min(layoutIndex, layouts.length - 1)] : null
  property var rects: layout ? layout.rects : []
  property int zoneIndex: 0
  property var lastLayouts: ({})  // monitor description -> layout id

  property var targetScreen: {
    if (!mon) return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === mon.name) return screens[i]
    return null
  }

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.menu.selectedText
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int pad: Style.spacing.panelPadding
  property int thumbHeight: Style.space(56)

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function open(payloadJson) {
    root.error = ""
    root.win = null
    root.mon = null
    root.suggestion = null
    probe.running = true
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "dbarke.zones")
  }

  function firstNumber(opt, fallback) {
    if (!opt) return fallback
    if (typeof opt.int === "number") return opt.int
    var n = parseInt(String(opt.css || opt.custom || ""), 10)
    return isFinite(n) ? n : fallback
  }

  function load(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { root.fail("Couldn't read the window list from hyprctl."); return }
    var win = data.win
    if (!win || !win.address) { root.fail("No active window to place."); return }
    if (win.fullscreen) { root.fail("Leave fullscreen first (Super+F), then try again."); return }
    var mon = (data.mons || []).filter(function(m) { return m.id === win.monitor })[0]
    if (!mon) { root.fail("Couldn't tell which monitor the window is on."); return }

    root.win = win
    root.mon = mon
    root.area = Layouts.area(mon, {
      gapsOut: root.firstNumber(data.gout, 0),
      gapsIn: root.firstNumber(data.gin, 0),
      border: root.firstNumber(data.border, 0)
    })
    root.suggestion = Layouts.suggest(root.area)

    var last = root.lastLayouts[mon.description]
    var idx = 0
    for (var i = 0; i < root.layouts.length; i++)
      if (root.layouts[i].id === last) idx = i
    root.selectLayout(idx)
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function fail(message) {
    root.error = message
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Preselect the zone the window already sits in, so Enter is a no-op
  // rather than a surprise jump.
  function selectLayout(i) {
    if (!root.layouts.length) return
    root.layoutIndex = (i + root.layouts.length) % root.layouts.length
    var cx = root.win.at[0] + root.win.size[0] / 2
    var cy = root.win.at[1] + root.win.size[1] / 2
    root.zoneIndex = Math.max(0, Layouts.zoneAt(root.rects, cx, cy))
  }

  function apply(i) {
    if (!root.layout || i < 0 || i >= root.rects.length) return
    applyProc.command = ["hyprctl", "eval", Layouts.applyLua(root.win.address, root.rects[i])]
    applyProc.running = true
    var next = Object.assign({}, root.lastLayouts)
    next[root.mon.description] = root.layout.id
    root.lastLayouts = next
    stateFile.setText(JSON.stringify(next, null, 2) + "\n")
    root.dismiss()
  }

  // One process for everything the overlay needs, so the zones are drawn
  // from a single consistent snapshot.
  Process {
    id: probe
    command: ["sh", "-c",
      "printf '{\"win\":'; hyprctl -j activewindow;"
      + " printf ',\"mons\":'; hyprctl -j monitors;"
      + " printf ',\"gin\":'; hyprctl -j getoption general:gaps_in;"
      + " printf ',\"gout\":'; hyprctl -j getoption general:gaps_out;"
      + " printf ',\"border\":'; hyprctl -j getoption general:border_size;"
      + " printf '}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.load(text)
    }
  }

  Process { id: applyProc }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { root.lastLayouts = JSON.parse(text()) || ({}) } catch (e) { root.lastLayouts = ({}) }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "dbarke-zones"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var k = event.key
        var n = root.rects.length
        if (k === Qt.Key_Escape || k === Qt.Key_Q) root.dismiss()
        else if (root.error !== "") root.dismiss()
        else if (k >= Qt.Key_1 && k <= Qt.Key_9) root.apply(k - Qt.Key_1)
        else if (k === Qt.Key_Tab || k === Qt.Key_Down) root.selectLayout(root.layoutIndex + 1)
        else if (k === Qt.Key_Backtab || k === Qt.Key_Up) root.selectLayout(root.layoutIndex - 1)
        else if (k === Qt.Key_Right) root.zoneIndex = (root.zoneIndex + 1) % n
        else if (k === Qt.Key_Left) root.zoneIndex = (root.zoneIndex - 1 + n) % n
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) root.apply(root.zoneIndex)
        else return
        event.accepted = true
      }
    }

    // The zones, at the size and place the window will take.
    Repeater {
      model: root.error === "" ? root.rects : []

      Rectangle {
        id: zone
        required property var modelData
        required property int index
        property bool current: index === root.zoneIndex

        x: modelData.frameX - root.area.monX
        y: modelData.frameY - root.area.monY
        width: modelData.frameW
        height: modelData.frameH
        radius: root.cornerRadius
        color: root.tint(root.accent, current ? 0.22 : 0.08)
        border.color: root.tint(root.accent, current ? 0.9 : 0.35)
        border.width: Math.max(2, Style.space(2))

        Column {
          anchors.centerIn: parent
          spacing: Style.spacing.sm

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: String(zone.index + 1)
            color: root.foreground
            opacity: zone.current ? 1 : 0.6
            font.family: root.fontFamily
            font.pixelSize: Math.min(Style.space(96), zone.height / 4)
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: zone.modelData.frameW + " × " + zone.modelData.frameH
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (containsMouse) root.zoneIndex = zone.index
          onClicked: root.apply(zone.index)
        }
      }
    }

    // Layout picker: a thumbnail per suggested layout, best first.
    BorderSurface {
      id: card
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(48)
      width: Math.min(parent.width - Style.gapsOut * 4, Math.max(thumbs.implicitWidth, Style.space(560)) + contentLeftInset + contentRightInset)
      height: cardContent.implicitHeight + contentTopInset + contentBottomInset
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.pad

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: cardContent
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        spacing: Style.spacing.lg

        Text {
          width: parent.width
          visible: root.error !== ""
          text: root.error
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          width: parent.width
          visible: root.error === ""
          elide: Text.ElideRight
          text: root.win ? "Place  " + root.win.title : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          visible: root.error === "" && root.area !== null
          text: root.area && root.suggestion
            ? root.suggestion.shapeLabel + " · " + root.area.width + " × " + root.area.height
              + (root.mon ? "  ·  " + root.mon.description.replace(/\s+\S+$/, "") : "")
            : ""
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          id: thumbs
          visible: root.error === ""
          spacing: Style.spacing.lg

          Repeater {
            model: root.layouts

            Item {
              id: thumb
              required property var modelData
              required property int index
              property bool current: index === root.layoutIndex
              property real aspect: root.area ? root.area.w / root.area.h : 16 / 9

              width: Math.max(box.width, label.implicitWidth)
              height: box.height + Style.spacing.sm + label.implicitHeight + badge.height

              Rectangle {
                id: box
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.round(Math.min(root.thumbHeight * thumb.aspect, root.thumbHeight * 2.4))
                height: root.thumbHeight
                radius: Math.min(root.cornerRadius, Style.space(4))
                color: thumb.current ? root.selectedBackground : "transparent"
                border.color: root.tint(root.foreground, thumb.current ? 0.9 : 0.25)
                border.width: 1

                Repeater {
                  model: thumb.modelData.zones

                  Rectangle {
                    required property var modelData
                    x: 3 + modelData[0] * (box.width - 6) + 1
                    y: 3 + modelData[1] * (box.height - 6) + 1
                    width: modelData[2] * (box.width - 6) - 2
                    height: modelData[3] * (box.height - 6) - 2
                    radius: 2
                    color: root.tint(thumb.current ? root.accent : root.foreground, thumb.current ? 0.55 : 0.2)
                  }
                }
              }

              Text {
                id: label
                anchors.top: box.bottom
                anchors.topMargin: Style.spacing.sm
                anchors.horizontalCenter: parent.horizontalCenter
                text: thumb.modelData.name
                color: thumb.current ? root.accent : root.foreground
                opacity: thumb.current ? 1 : 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                id: badge
                anchors.top: label.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                text: thumb.index === 0 ? "suggested" : ""
                height: text === "" ? 0 : implicitHeight
                color: root.accent
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall * 0.85
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectLayout(thumb.index)
              }
            }
          }
        }

        Text {
          visible: root.error === "" && root.layout !== null
          text: root.layout ? root.layout.summary + (root.layout.reason ? "  ·  " + root.layout.reason : "") : ""
          color: root.foreground
          opacity: 0.8
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          text: root.error !== ""
            ? "Any key: close"
            : "1–" + Math.max(1, root.rects.length) + " or click: place   ·   ←/→ zone, Enter: place   ·   Tab/↑↓: layout   ·   Esc: close"
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
