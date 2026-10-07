# omarchy-zones

Snap windows into zones of their monitor, for [Omarchy](https://omarchy.org/):
pick a zone from the keyboard, or drop a window into one while dragging, and
save whole arrangements that come back when the monitor reconnects.

`Super+Z` draws the zones of a layout over the window's monitor at real size.
Press a number, or click a zone, and the window floats into it. The layouts on
offer depend on the monitor: an ultrawide gets thirds first, a 16:9 screen
halves, a portrait screen rows. A layout is left out when its zones would come
out narrower than 640 px or shorter than 480 px, so a laptop panel only offers
halves, centered and full.

Zones line up with Hyprland's own tiling: they sit inside the bar and
`gaps_out`, and neighbouring zones are as far apart as two tiled windows. A
zone covering the whole screen gives the same size and position as a single
tiled window.

## Install

```bash
omarchy plugin add https://github.com/dbarke/omarchy-zones.git --enable
```

Then bind keys in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + Z", "Window zones", "omarchy-shell shell toggle dbarke.zones")

-- Optional: Super+Shift+drag drops the window into the zone under the cursor.
-- The two non-consuming binds must come before the drag bind.
o.bind("SUPER + SHIFT + mouse:272", "Show zones while dragging", "omarchy-shell -q dbarke.zones dragStart", { non_consuming = true })
o.bind("SUPER + SHIFT + mouse:272", "Snap dragged window into zone", "omarchy-shell -q dbarke.zones dragEnd", { release = true, non_consuming = true })
o.bind("SUPER + SHIFT + mouse:272", "Drag window into a zone", hl.dsp.window.drag(), { mouse = true })
```

The shell registers the plugin's IPC target (`dragStart`, `dragEnd`, `save`,
`restore`) when it starts, so after installing, restart it once
(`omarchy restart shell`).

## Use

| Key | Action |
|---|---|
| `1`–`9`, click | Place the window in that zone |
| `←` / `→`, `Enter` | Pick a zone, place it |
| `Tab` / `↑` / `↓`, click a thumbnail | Switch layout |
| `T` | Toggle tile mode (remembered) |
| `S` | Save this monitor's arrangement |
| `A` | Restore it |
| `Esc` | Close |

The zone the window already sits in is preselected. Placed windows are
ordinary floating windows; `Super+T` tiles one again.

### Tile mode

With tile mode on, a full-height zone tiles the window instead of floating it:
the window is swapped with the tiled window sitting where the zone is, then
its dwindle split or scrolling column is resized to the zone's width. Hyprland's
layouts don't take positions, so this has limits: a lone tiled window always
fills the workspace, and on a scrolling workspace the column gets the zone's
width while the layout decides where the view scrolls. Stacked zones (quarters,
main + stack) always float.

### Dragging

Super+Shift+drag moves a window as Super+drag does, with the zones of the
monitor under the cursor drawn click-through. Releasing the mouse button drops
the window into the zone under the cursor, using that monitor's last layout
(or the suggested one). Release the mouse button before Shift, or the release
bind won't fire.

### Arrangements

`S` saves where every window on the monitor's visible workspace sits — as
fractions of the screen, so it survives a resolution change. They come back:

- with `A` in the picker (or `omarchy-shell dbarke.zones restore`),
- when that monitor is connected again,
- for a newly opened window whose app is in an arrangement, when no other
  window of that app is open. A PWA like Teams lands in its place every time;
  a fifth browser window is left alone.

Windows are matched by app (initial class), preferring the same first title and
windows already on the target workspace. Restoring brings them to whichever
workspace that monitor is showing.

The last layout used on each monitor, tile mode and arrangements are kept (by
monitor description, so they survive a different port) in
`~/.local/state/omarchy/zones.json`.

## Layouts

| Monitor | Offered, best first |
|---|---|
| Ultrawide (≥ 2.1:1) | Thirds, Halves, Center focus (¼ ½ ¼), ⅔ + ⅓, ⅓ + ⅔, Main + stack, Centered, Sixths, Quarters, Full |
| Widescreen | Halves, ⅔ + ⅓, ⅓ + ⅔, Quarters, Main + stack, Thirds, Centered, Full |
| Square-ish | Halves, Top / bottom, Quarters, Centered, Full |
| Portrait | Top / bottom, Rows of thirds, Halves, Full |

The catalog and the per-shape order live in `layouts.js`.
