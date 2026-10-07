.pragma library

// Zone layouts and the geometry that turns them into window rectangles.
//
// Pure functions, no QML: Zones.qml feeds in `hyprctl -j monitors` and the
// gap/border options, and gets back which layouts suit that monitor (best
// first) and where each zone's window goes, in Hyprland's global coordinates.

// A zone narrower or shorter than this is not worth offering: below ~640 px a
// browser drops into its mobile layout, and below ~480 px little fits at all.
var MIN_ZONE_WIDTH = 640
var MIN_ZONE_HEIGHT = 480

// Zones are [x, y, w, h] fractions of the usable area (inside the bar and
// gaps_out). `center` depends on the monitor, so it is built in suggest().
var CATALOG = {
  "full":        { name: "Full",            zones: [[0, 0, 1, 1]] },
  "halves":      { name: "Halves",          zones: [[0, 0, 1/2, 1], [1/2, 0, 1/2, 1]] },
  "thirds":      { name: "Thirds",          zones: [[0, 0, 1/3, 1], [1/3, 0, 1/3, 1], [2/3, 0, 1/3, 1]] },
  "two-one":     { name: "⅔ + ⅓",           zones: [[0, 0, 2/3, 1], [2/3, 0, 1/3, 1]] },
  "one-two":     { name: "⅓ + ⅔",           zones: [[0, 0, 1/3, 1], [1/3, 0, 2/3, 1]] },
  "focus":       { name: "Center focus",    zones: [[0, 0, 1/4, 1], [1/4, 0, 1/2, 1], [3/4, 0, 1/4, 1]] },
  "main-stack":  { name: "Main + stack",    zones: [[0, 0, 2/3, 1], [2/3, 0, 1/3, 1/2], [2/3, 1/2, 1/3, 1/2]] },
  "quarters":    { name: "Quarters",        zones: [[0, 0, 1/2, 1/2], [1/2, 0, 1/2, 1/2], [0, 1/2, 1/2, 1/2], [1/2, 1/2, 1/2, 1/2]] },
  "sixths":      { name: "Sixths",          zones: [[0, 0, 1/3, 1/2], [1/3, 0, 1/3, 1/2], [2/3, 0, 1/3, 1/2],
                                                     [0, 1/2, 1/3, 1/2], [1/3, 1/2, 1/3, 1/2], [2/3, 1/2, 1/3, 1/2]] },
  "rows":        { name: "Top / bottom",    zones: [[0, 0, 1, 1/2], [0, 1/2, 1, 1/2]] },
  "row-thirds":  { name: "Rows of thirds",  zones: [[0, 0, 1, 1/3], [0, 1/3, 1, 1/3], [0, 2/3, 1, 1/3]] }
}

// Preference order per monitor shape. Layouts whose zones come out too small
// on the actual monitor are dropped afterwards, so a list can be generous.
var ORDER = {
  "ultrawide": ["thirds", "halves", "focus", "two-one", "one-two", "main-stack", "center", "sixths", "quarters", "full"],
  "wide":      ["halves", "two-one", "one-two", "quarters", "main-stack", "thirds", "center", "full"],
  "square":    ["halves", "rows", "quarters", "center", "full"],
  "portrait":  ["rows", "row-thirds", "halves", "full"]
}

var SHAPE_LABEL = { "ultrawide": "Ultrawide", "wide": "Widescreen", "square": "Square", "portrait": "Portrait" }

function shapeOf(width, height) {
  var a = width / height
  if (a >= 2.1) return "ultrawide"
  if (a >= 1.2) return "wide"
  if (a >= 0.9) return "square"
  return "portrait"
}

// Logical size and usable area of a `hyprctl -j monitors` entry.
// `opts` = { gapsOut, gapsIn, border } in logical px.
function area(mon, opts) {
  var scale = mon.scale || 1
  var rotated = (mon.transform % 2) === 1
  var w = Math.round((rotated ? mon.height : mon.width) / scale)
  var h = Math.round((rotated ? mon.width : mon.height) / scale)
  var r = mon.reserved || [0, 0, 0, 0] // left, top, right, bottom
  var g = opts.gapsOut
  return {
    monX: mon.x, monY: mon.y, width: w, height: h,
    x: mon.x + r[0] + g,
    y: mon.y + r[1] + g,
    w: w - r[0] - r[2] - 2 * g,
    h: h - r[1] - r[3] - 2 * g,
    gapsIn: opts.gapsIn, border: opts.border
  }
}

// Fractions -> the window's own rectangle (Hyprland's `at`/`size`, which
// exclude the border). Neighbours sit 2 × gaps_in apart, like tiled windows.
// Scaling the fractions over (w + 2g) and trimming 2g off the far edge
// splits that spacing evenly, so equal fractions give equal widths.
function zoneRect(a, z) {
  var g2 = 2 * a.gapsIn
  var x0 = Math.round(a.x + z[0] * (a.w + g2))
  var x1 = Math.round(a.x + (z[0] + z[2]) * (a.w + g2) - g2)
  var y0 = Math.round(a.y + z[1] * (a.h + g2))
  var y1 = Math.round(a.y + (z[1] + z[3]) * (a.h + g2) - g2)
  return { x: x0 + a.border, y: y0 + a.border, w: x1 - x0 - 2 * a.border, h: y1 - y0 - 2 * a.border,
           frameX: x0, frameY: y0, frameW: x1 - x0, frameH: y1 - y0 }
}

function centerZones(shape) {
  var w = shape === "ultrawide" ? 0.5 : (shape === "wide" ? 0.7 : 0.8)
  return [[(1 - w) / 2, 0, w, 1]]
}

// Short summary of the zone sizes, e.g. "3 zones · 1139 × 1402" or
// "2283 × 1402 · 1139 × 698". Sizes within a pixel or two of each other
// (rounding) count as the same size.
function describe(rects) {
  var uniq = []
  rects.forEach(function(r) {
    var seen = uniq.some(function(u) { return Math.abs(u.frameW - r.frameW) <= 2 && Math.abs(u.frameH - r.frameH) <= 2 })
    if (!seen) uniq.push(r)
  })
  var sizes = uniq.map(function(r) { return r.frameW + " × " + r.frameH })
  if (uniq.length === 1 && rects.length > 1) return rects.length + " zones · " + sizes[0]
  return sizes.join(" · ")
}

function reasonFor(id, shape) {
  if (shape === "ultrawide" && id === "thirds")
    return "Three columns, each about as wide as a laptop screen."
  if (shape === "ultrawide" && id === "focus")
    return "One main window straight ahead, side panels for chat and notes."
  if (shape === "wide" && id === "halves")
    return "Two full-height windows side by side."
  if (shape === "portrait" && id === "rows")
    return "Stacked: a portrait screen has more height than width to share."
  if (id === "full") return "This screen is too small to split comfortably."
  return ""
}

// Layouts that fit this monitor, best first:
// [{ id, name, zones, rects, summary, reason }]
function suggest(a) {
  var shape = shapeOf(a.width, a.height)
  var out = []
  var order = ORDER[shape]
  for (var i = 0; i < order.length; i++) {
    var id = order[i]
    var def = id === "center" ? { name: "Centered", zones: centerZones(shape) } : CATALOG[id]
    var rects = def.zones.map(function(z) { return zoneRect(a, z) })
    var fits = rects.every(function(r) { return r.frameW >= MIN_ZONE_WIDTH && r.frameH >= MIN_ZONE_HEIGHT })
    if (!fits && id !== "full") continue
    out.push({ id: id, name: def.name, zones: def.zones, rects: rects, summary: describe(rects), reason: "" })
  }
  if (out.length) out[0].reason = reasonFor(out[0].id, shape)
  return { shape: shape, shapeLabel: SHAPE_LABEL[shape], layouts: out }
}

// Index of the zone whose rectangle holds the point, or -1.
function zoneAt(rects, px, py) {
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i]
    if (px >= r.frameX && px < r.frameX + r.frameW && py >= r.frameY && py < r.frameY + r.frameH) return i
  }
  return -1
}

// Lua for `hyprctl eval`: float the window, size it, then place it. Resizing
// a floating window keeps its center, so the move has to come last.
function applyLua(address, r) {
  var w = "'address:" + address + "'"
  return "hl.dispatch(hl.dsp.window.float({ action = 'enable', window = " + w + " })) "
    + "hl.dispatch(hl.dsp.window.resize({ x = " + r.w + ", y = " + r.h + ", window = " + w + " })) "
    + "hl.dispatch(hl.dsp.window.move({ x = " + r.x + ", y = " + r.y + ", window = " + w + " }))"
}
