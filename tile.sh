#!/bin/bash
# Tile a window and fit it to a zone: tile.sh <address> <x> <width>
#
# Hyprland's layouts don't take positions, so this works the way the
# Omarchy window-width script does: tile the window, swap it with the tiled
# window that sits where the zone is, then nudge its width
# with relative resizes (which move the dwindle split or the scrolling
# column) until it matches. x and width are the window's own `at`/`size`.
set -uo pipefail

address="$1"
target_x="$2"
target_w="$3"
win="address:$address"

geom() {
  hyprctl clients -j | jq -r --arg a "$address" '.[] | select(.address == $a) | "\(.at[0]) \(.size[0]) \(.floating)"'
}

lua() { hyprctl eval "$1" >/dev/null; }

lua "hl.dispatch(hl.dsp.window.float({ action = 'disable', window = '$win' }))"
sleep 0.05

read -r x w floating < <(geom) || exit 1
[[ $floating == false ]] || exit 1

# Swap with the tiled neighbour sitting where the zone is, if any. Swapping
# acts on the active window, which is ours when placed from the overlay.
target_c=$((target_x + target_w / 2))
c=$((x + w / 2))
if ((c < target_x || c > target_x + target_w)); then
  ws=$(hyprctl clients -j | jq -r --arg a "$address" '.[] | select(.address == $a) | .workspace.id')
  other=$(hyprctl clients -j | jq -r --arg a "$address" --argjson ws "$ws" --argjson tc "$target_c" '
    [.[] | select(.workspace.id == $ws and .floating == false and .address != $a and .mapped)
         | {address, d: ((.at[0] + .size[0] / 2) - $tc | fabs)}]
    | sort_by(.d) | first | .address // empty')
  if [[ -n $other ]]; then
    active=$(hyprctl activewindow -j | jq -r '.address // empty')
    [[ $active == "$address" ]] || lua "hl.dispatch(hl.dsp.focus({ window = '$win' }))"
    lua "hl.dispatch(hl.dsp.window.swap({ target = 'address:$other' }))"
    sleep 0.05
    read -r x w _ < <(geom) || exit 1
  fi
fi

# Resize towards the target width. Which edge moves depends on the layout and
# the window's position, so the first step's effect tells us the direction.
dir=1
for _ in 1 2 3 4 5 6; do
  delta=$((target_w - w))
  ((delta > -3 && delta < 3)) && break
  lua "hl.dispatch(hl.dsp.window.resize({ window = '$win', x = $((delta * dir)), y = 0, relative = true }))"
  sleep 0.05
  read -r x nw _ < <(geom) || exit 1
  if ((nw == w)); then break; fi
  if (( (nw - w) * delta < 0 )); then dir=$((-dir)); fi
  w=$nw
done
