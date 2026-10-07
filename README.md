# omarchy-zones

Snap the active window into a zone of its monitor, for
[Omarchy](https://omarchy.org/).

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

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + Z", "Window zones", "omarchy-shell shell toggle dbarke.zones")
```

## Use

| Key | Action |
|---|---|
| `1`–`9`, click | Place the window in that zone |
| `←` / `→`, `Enter` | Pick a zone, place it |
| `Tab` / `↑` / `↓`, click a thumbnail | Switch layout |
| `Esc` | Close |

The zone the window already sits in is preselected. Placed windows are
ordinary floating windows; `Super+T` tiles one again.

The last layout used on each monitor is remembered (by monitor description, so
it survives a different port) in `~/.local/state/omarchy/zones.json`.

## Layouts

| Monitor | Offered, best first |
|---|---|
| Ultrawide (≥ 2.1:1) | Thirds, Halves, Center focus (¼ ½ ¼), ⅔ + ⅓, ⅓ + ⅔, Main + stack, Centered, Sixths, Quarters, Full |
| Widescreen | Halves, ⅔ + ⅓, ⅓ + ⅔, Quarters, Main + stack, Thirds, Centered, Full |
| Square-ish | Halves, Top / bottom, Quarters, Centered, Full |
| Portrait | Top / bottom, Rows of thirds, Halves, Full |

The catalog and the per-shape order live in `layouts.js`.
