import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "layouts.js" as Layouts

// Snap windows into zones of their monitor.
//
// Picker (Super+Z): reads the active window, the monitors and the gap/border
// options from hyprctl in one go, asks layouts.js which layouts suit that
// monitor (an ultrawide gets thirds first, a laptop panel only halves), and
// draws the selected layout's zones at real size over the monitor. Picking a
// zone floats the window there, or in tile mode tiles it and fits the split
// or column to the zone's width (tile.sh).
//
// Drag (Super+Shift+drag): the bindings call dragStart/dragEnd over IPC. The
// zones of the monitor under the cursor are shown click-through while the
// window moves, and the one under the cursor on release takes the window.
//
// Arrangements: S in the picker saves where every window on that monitor's
// visible workspace sits, as fractions of the usable area. They come back with A, when the
// monitor is connected again, and for a window that opens while no other
// window of its app exists (a PWA like Teams, not the fifth browser window).
//
// State in ~/.local/state/omarchy/zones.json, keyed by monitor description so
// it survives a different port.
Item {
  id: root

  property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/zones.json"
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string mode: "pick"    // "pick" (keyboard overlay) or "drag" (click-through)
  property string error: ""
  property var snap: null         // last probe: { win, mons, clients, opts, cursor }
  property var win: null          // window being placed
  property var mon: null          // monitor entry the zones are drawn on
  property var area: null         // Layouts.area(mon, ...)
  property var suggestion: null   // Layouts.suggest(area)
  property var layouts: suggestion ? suggestion.layouts : []
  property int layoutIndex: 0
  property var layout: layouts.length ? layouts[Math.min(layoutIndex, layouts.length - 1)] : null
  property var rects: layout ? layout.rects : []
  property int zoneIndex: 0

  property var state: ({ lastLayouts: {}, tile: false, arrangements: {} })
  property bool tileMode: state.tile === true
  property var savedHere: mon && state.arrangements ? state.arrangements[mon.description] || null : null

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

  // ------------------------------------------------------------ shell hooks

  function open(payloadJson) {
    root.mode = "pick"
    root.error = ""
    root.probe(function(s) { root.startPick(s) })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "dbarke.zones")
  }

  // ---------------------------------------------------------------- probing

  property var probeQueue: []

  // Everything comes from one hyprctl snapshot, so zones, windows and
  // monitors always agree with each other.
  function probe(callback) {
    var q = root.probeQueue.slice()
    q.push(callback)
    root.probeQueue = q
    if (!probeProc.running) probeProc.running = true
  }

  function firstNumber(opt, fallback) {
    if (!opt) return fallback
    if (typeof opt.int === "number") return opt.int
    var n = parseInt(String(opt.css || opt.custom || ""), 10)
    return isFinite(n) ? n : fallback
  }

  function probed(text) {
    var q = root.probeQueue
    root.probeQueue = []
    var data = null
    try { data = JSON.parse(text) } catch (e) { data = null }
    var s = data ? {
      win: data.win && data.win.address ? data.win : null,
      mons: data.mons || [],
      clients: data.clients || [],
      cursor: data.cursor || null,
      opts: {
        gapsOut: root.firstNumber(data.gout, 0),
        gapsIn: root.firstNumber(data.gin, 0),
        border: root.firstNumber(data.border, 0)
      }
    } : null
    root.snap = s
    for (var i = 0; i < q.length; i++) q[i](s)
  }

  function monitorById(s, id) {
    return s.mons.filter(function(m) { return m.id === id })[0] || null
  }

  function monitorByDesc(s, desc) {
    return s.mons.filter(function(m) { return m.description === desc })[0] || null
  }

  function showMonitor(s, mon) {
    root.mon = mon
    root.area = Layouts.area(mon, s.opts)
    root.suggestion = Layouts.suggest(root.area)
    var last = (root.state.lastLayouts || {})[mon.description]
    var idx = 0
    for (var i = 0; i < root.layouts.length; i++)
      if (root.layouts[i].id === last) idx = i
    root.layoutIndex = idx
  }

  // ------------------------------------------------------------------ picker

  function startPick(s) {
    if (!s) { root.fail("Couldn't read the window list from hyprctl."); return }
    if (!s.win) { root.fail("No active window to place."); return }
    if (s.win.fullscreen) { root.fail("Leave fullscreen first (Super+F), then try again."); return }
    var mon = root.monitorById(s, s.win.monitor)
    if (!mon) { root.fail("Couldn't tell which monitor the window is on."); return }
    root.win = s.win
    root.showMonitor(s, mon)
    root.selectLayout(root.layoutIndex)
    root.opened = true
  }

  function fail(message) {
    root.error = message
    // The message needs a monitor to show on; use the focused one.
    var focused = root.snap ? root.snap.mons.filter(function(m) { return m.focused })[0] : null
    if (focused) root.mon = focused
    root.mode = "pick"
    root.opened = true
  }

  // Preselect the zone the window already sits in, so Enter is a no-op
  // rather than a surprise jump.
  function selectLayout(i) {
    if (!root.layouts.length) return
    root.layoutIndex = (i + root.layouts.length) % root.layouts.length
    if (!root.win) return
    var cx = root.win.at[0] + root.win.size[0] / 2
    var cy = root.win.at[1] + root.win.size[1] / 2
    root.zoneIndex = Math.max(0, Layouts.zoneAt(root.rects, cx, cy))
  }

  function rememberLayout() {
    var next = Object.assign({}, root.state)
    next.lastLayouts = Object.assign({}, next.lastLayouts || {})
    next.lastLayouts[root.mon.description] = root.layout.id
    root.saveState(next)
  }

  function placeInZone(address, i) {
    var z = root.layout.zones[i]
    var r = root.rects[i]
    if (root.tileMode && Layouts.fullHeight(z))
      root.run(["bash", root.pluginDir + "tile.sh", address, String(r.x), String(r.w)])
    else
      root.lua(Layouts.applyLua(address, r))
  }

  function apply(i) {
    if (!root.layout || !root.win || i < 0 || i >= root.rects.length) return
    root.placeInZone(root.win.address, i)
    root.rememberLayout()
    root.dismiss()
  }

  function toggleTile() {
    var next = Object.assign({}, root.state)
    next.tile = !root.tileMode
    root.saveState(next)
  }

  // ---------------------------------------------------------------- dragging

  property bool dragging: false

  function dragStart() {
    root.dragging = true
    root.probe(function(s) {
      if (!root.dragging || !s || !s.cursor) return
      var mon = Layouts.monitorAt(s.mons, s.opts, s.cursor.x, s.cursor.y)
      if (!mon) return
      root.mode = "drag"
      root.error = ""
      root.win = null
      root.showMonitor(s, mon)
      root.zoneIndex = Layouts.zoneAt(root.rects, s.cursor.x, s.cursor.y)
      root.opened = true
      cursorTimer.start()
    })
  }

  function dragEnd() {
    if (!root.dragging) return
    root.dragging = false
    cursorTimer.stop()
    root.probe(function(s) {
      root.opened = false
      root.mode = "pick"
      if (!s || !s.win || !s.cursor) return
      var mon = Layouts.monitorAt(s.mons, s.opts, s.cursor.x, s.cursor.y)
      if (!mon) return
      if (!root.mon || mon.id !== root.mon.id) root.showMonitor(s, mon)
      var i = Layouts.zoneAt(root.rects, s.cursor.x, s.cursor.y)
      if (i < 0) return
      root.placeInZone(s.win.address, i)
      root.rememberLayout()
    })
  }

  function trackCursor(text) {
    var c = null
    try { c = JSON.parse(text) } catch (e) { return }
    if (!root.dragging || !root.snap || !c) return
    var mon = Layouts.monitorAt(root.snap.mons, root.snap.opts, c.x, c.y)
    if (mon && (!root.mon || mon.id !== root.mon.id)) root.showMonitor(root.snap, mon)
    root.zoneIndex = Layouts.zoneAt(root.rects, c.x, c.y)
  }

  Timer {
    id: cursorTimer
    interval: 50
    repeat: true
    onTriggered: if (!cursorProc.running) cursorProc.running = true
  }

  Process {
    id: cursorProc
    command: ["hyprctl", "-j", "cursorpos"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.trackCursor(text)
    }
  }

  // ----------------------------------------------------------- arrangements

  function arrangementFor(s, mon) {
    var a = Layouts.area(mon, s.opts)
    return s.clients
      // Only the workspace on screen: restoring brings windows to whatever
      // workspace that monitor shows then, so saving others would pile them up.
      .filter(function(c) { return c.mapped && !c.hidden && c.workspace && mon.activeWorkspace && c.workspace.id === mon.activeWorkspace.id })
      .map(function(c) {
        return {
          cls: c.initialClass, title: c.initialTitle, floating: c.floating,
          f: c.floating ? Layouts.toFractions(a, c.at, c.size) : null
        }
      })
  }

  function saveArrangement() {
    if (!root.snap || !root.mon) return
    root.saveArrangementOn(root.snap, root.mon)
    root.dismiss()
  }

  function saveArrangementOn(snap, mon) {
    var entries = root.arrangementFor(snap, mon)
    var next = Object.assign({}, root.state)
    next.arrangements = Object.assign({}, next.arrangements || {})
    next.arrangements[mon.description] = entries
    root.saveState(next)
    root.notify("Saved " + entries.length + " window" + (entries.length === 1 ? "" : "s")
      + " on " + root.shortName(mon), "Super+Z, then A puts them back; they also return when the monitor reconnects.")
  }

  // Best unused window for an entry: same app, then same first title, then
  // already on the target workspace.
  function matchWindow(s, entry, used, workspace) {
    var best = null, bestScore = -1
    s.clients.forEach(function(c) {
      if (used[c.address] || c.initialClass !== entry.cls || !c.mapped) return
      var score = (c.initialTitle === entry.title ? 2 : 0) + (c.workspace && c.workspace.id === workspace ? 1 : 0)
      if (score > bestScore) { best = c; bestScore = score }
    })
    return best
  }

  function placeEntry(s, mon, entry, c) {
    var ws = mon.activeWorkspace ? mon.activeWorkspace.id : null
    var cmds = []
    if (ws !== null && (!c.workspace || c.workspace.id !== ws)) cmds.push(Layouts.moveToWorkspaceLua(c.address, ws))
    if (entry.floating && entry.f) cmds.push(Layouts.applyLua(c.address, Layouts.fromFractions(Layouts.area(mon, s.opts), entry.f)))
    else if (!entry.floating && c.floating) cmds.push(Layouts.tileLua(c.address))
    if (cmds.length) root.lua(cmds.join(" "))
  }

  function restoreArrangement(s, mon) {
    var entries = (root.state.arrangements || {})[mon.description]
    if (!entries || !entries.length) return 0
    var ws = mon.activeWorkspace ? mon.activeWorkspace.id : null
    var used = ({})
    var placed = 0
    entries.forEach(function(entry) {
      var c = root.matchWindow(s, entry, used, ws)
      if (!c) return
      used[c.address] = true
      root.placeEntry(s, mon, entry, c)
      placed++
    })
    return placed
  }

  function restoreHere() {
    if (!root.snap || !root.mon) return
    var n = root.restoreArrangement(root.snap, root.mon)
    if (!n) root.notify("Nothing saved for " + root.shortName(root.mon), "Arrange the windows, then Super+Z and S.")
    root.dismiss()
  }

  // A new window whose app is in a saved arrangement goes to its place,
  // unless another window of that app is already open (then it's just one
  // more browser window, not the one the arrangement meant).
  function placeNewWindow(address) {
    root.probe(function(s) {
      if (!s) return
      var c = s.clients.filter(function(x) { return x.address === address })[0]
      if (!c) return
      if (s.clients.some(function(x) { return x.address !== address && x.initialClass === c.initialClass })) return
      var arrangements = root.state.arrangements || {}
      for (var desc in arrangements) {
        var mon = root.monitorByDesc(s, desc)
        if (!mon) continue
        var entry = (arrangements[desc] || []).filter(function(e) { return e.cls === c.initialClass })[0]
        if (!entry) continue
        root.placeEntry(s, mon, entry, c)
        return
      }
    })
  }

  property var pendingMonitors: []

  Timer {
    id: monitorTimer
    // Give Hyprland time to move workspaces onto the new output first.
    interval: 1500
    onTriggered: {
      var descs = root.pendingMonitors
      root.pendingMonitors = []
      root.probe(function(s) {
        if (!s) return
        descs.forEach(function(desc) {
          var mon = root.monitorByDesc(s, desc)
          if (mon) root.restoreArrangement(s, mon)
        })
      })
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      var data = String(event.data || "")
      if (name === "openwindow") {
        var address = "0x" + data.split(",")[0]
        // Let the window map and its rules (floating, size) apply first.
        Qt.callLater(function() { openTimer.addresses.push(address); openTimer.restart() })
      } else if (name === "monitoraddedv2") {
        var parts = data.split(",")
        var desc = parts.slice(2).join(",")
        if (desc && (root.state.arrangements || {})[desc]) {
          root.pendingMonitors = root.pendingMonitors.concat([desc])
          monitorTimer.restart()
        }
      }
    }
  }

  Timer {
    id: openTimer
    property var addresses: []
    interval: 400
    onTriggered: {
      var list = addresses
      addresses = []
      if (!Object.keys(root.state.arrangements || {}).length) return
      list.forEach(function(a) { root.placeNewWindow(a) })
    }
  }

  // ----------------------------------------------------------------- helpers

  function shortName(mon) {
    return String(mon.description || mon.name).replace(/\s+\S+$/, "")
  }

  property var runQueue: []

  function run(argv) {
    root.runQueue = root.runQueue.concat([argv])
    if (!runProc.running) root.runNext()
  }

  function runNext() {
    if (!root.runQueue.length) return
    runProc.command = root.runQueue[0]
    root.runQueue = root.runQueue.slice(1)
    runProc.running = true
  }

  function lua(code) { root.run(["hyprctl", "eval", code]) }

  function notify(title, body) {
    root.run(["omarchy-notification-send", "-g", title, body])
  }

  function saveState(next) {
    root.state = next
    stateFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  // 0.1 stored a flat { description: layout } map.
  function loadState(text) {
    var s = null
    try { s = JSON.parse(text) } catch (e) { s = null }
    if (!s || typeof s !== "object") s = {}
    if (!s.lastLayouts && !s.arrangements && s.tile === undefined) s = { lastLayouts: s }
    s.lastLayouts = s.lastLayouts || {}
    s.arrangements = s.arrangements || {}
    s.tile = s.tile === true
    root.state = s
  }

  Process {
    id: probeProc
    command: ["sh", "-c",
      "printf '{\"win\":'; hyprctl -j activewindow;"
      + " printf ',\"mons\":'; hyprctl -j monitors;"
      + " printf ',\"clients\":'; hyprctl -j clients;"
      + " printf ',\"cursor\":'; hyprctl -j cursorpos;"
      + " printf ',\"gin\":'; hyprctl -j getoption general:gaps_in;"
      + " printf ',\"gout\":'; hyprctl -j getoption general:gaps_out;"
      + " printf ',\"border\":'; hyprctl -j getoption general:border_size;"
      + " printf '}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.probed(text)
    }
    onExited: if (root.probeQueue.length) Qt.callLater(function() { probeProc.running = true })
  }

  Process {
    id: runProc
    onExited: root.runNext()
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("{}")
  }

  IpcHandler {
    target: "dbarke.zones"
    function dragStart(): void { root.dragStart() }
    function dragEnd(): void { root.dragEnd() }
    function dragCancel(): void { root.dragging = false; cursorTimer.stop(); if (root.mode === "drag") root.opened = false }
    // Save / restore the arrangement of the focused monitor (or all, for restore).
    function save(): void {
      root.probe(function(s) {
        var mon = s ? s.mons.filter(function(m) { return m.focused })[0] : null
        if (mon) root.saveArrangementOn(s, mon)
      })
    }
    function restore(): void {
      root.probe(function(s) {
        if (!s) return
        s.mons.forEach(function(m) { root.restoreArrangement(s, m) })
      })
    }
  }

  Component {
    id: zoneDelegate

    Rectangle {
      id: zone
      required property var modelData
      required property int index
      property bool current: index === root.zoneIndex
      property bool tiles: root.mode === "pick" && root.tileMode && root.layout && Layouts.fullHeight(root.layout.zones[index])

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
          text: zone.modelData.frameW + " × " + zone.modelData.frameH + (zone.tiles ? "  ·  tiled" : "")
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: root.mode === "pick"
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: if (containsMouse) root.zoneIndex = zone.index
        onClicked: root.apply(zone.index)
      }
    }
  }


  // ------------------------------------------------------------------ window

  // Separate drag and picker windows: one window switching its mask and
  // keyboard focus between modes is asking for trouble with layer surfaces.

  // Drag mode: zones only, click-through, no keyboard, so the drag carries
  // on. One per monitor with a fixed screen; the one under the cursor shows.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.opened && root.mode === "drag" && root.mon !== null && root.mon.name === modelData.name
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "dbarke-zones-drag"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      Rectangle {
        anchors.fill: parent
        color: root.scrim
        opacity: 0.4
      }

      Repeater {
        model: root.mode === "drag" && root.area ? root.rects : []
        delegate: zoneDelegate
      }
    }
  }

  // Picker: one per monitor as well, each bound to its own screen for good.
  // A screen binding that follows the target monitor re-evaluates against
  // destroyed screens while the shell shuts down and crashes Quickshell.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      screen: modelData
      visible: root.opened && root.mode === "pick" && root.mon !== null && root.mon.name === modelData.name
      onVisibleChanged: if (visible) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
          else if (k === Qt.Key_T) root.toggleTile()
          else if (k === Qt.Key_S) root.saveArrangement()
          else if (k === Qt.Key_A) root.restoreHere()
          else return
          event.accepted = true
        }
      }

      // The zones, at the size and place the window will take.
      Repeater {
        model: root.mode === "pick" && root.error === "" && root.area ? root.rects : []
        delegate: zoneDelegate
      }

      // Layout picker: a thumbnail per suggested layout, best first.
      BorderSurface {
        id: card
        visible: root.mode === "pick"
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
            text: root.win ? (root.tileMode ? "Tile  " : "Place  ") + root.win.title : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }

          Text {
            visible: root.error === "" && root.area !== null
            text: root.area && root.suggestion
              ? root.suggestion.shapeLabel + " · " + root.area.width + " × " + root.area.height
                + (root.mon ? "  ·  " + root.shortName(root.mon) : "")
                + (root.savedHere ? "  ·  saved arrangement: " + root.savedHere.length + " windows" : "")
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
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.error !== ""
              ? "Any key: close"
              : "1–" + Math.max(1, root.rects.length) + " or click: place   ·   ←/→ zone, Enter: place   ·   Tab/↑↓: layout   ·   T: "
                + (root.tileMode ? "float instead" : "tile instead") + "   ·   S: save arrangement"
                + (root.savedHere ? "   ·   A: restore it" : "") + "   ·   Esc: close"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
