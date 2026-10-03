#!/usr/bin/env bash
# shell-local.sh — the GTK shell's presentation, checked on the real desktop (WOR-314 S4).
#
#   scripts/linux/shell-local.sh [offload] [--seconds N]     (any Wayland compositor)
#   scripts/linux/shell-local.sh checkerboard                 (Hyprland, grim, python3)
#
# Runs `tkzmux --presentation-check` (TKZMUX_BIN, default .build/debug/tkzmux; build it first)
# in the current session, so a window appears for a few seconds and closes itself. Never in CI:
# runners have no GPU and no compositor that takes dma-bufs (ADR-0002 D5).
#
# offload (the default): a 1-px checkerboard with a moving bar, a frame every frame-clock tick, for
#   N seconds (default 10), under GDK_DEBUG=offload (+ G_MESSAGES_DEBUG=all: the variable WOR-301
#   S1 recorded; GSK_DEBUG=offload is rejected) and WAYLAND_DEBUG=1. It passes when
#     - the check presented dma-bufs (--expect-dmabuf) on the compositor's main_device, and says so;
#     - GDK created the offload subsurface, and the trace has its wl_subcompositor.get_subsurface;
#     - that subsurface got at least 90% of the frames' wl_buffer attaches, so GSK composited
#       (almost) none of them; the main surface's attaches and every GDK "🗙" refusal are listed.
#   The traces stay in the directory it prints.
#
# checkerboard: the checkerboard alone, presented once, in a floating 800×500 window placed at three
#   positions with opacity forced to 1 (Omarchy tags every window with 0.985 opacity; the WOR-314
#   S3 snippet removes it for good). Each time it captures the window's rect with grim (at the
#   output's scale, so in device pixels) and compares it with a perfect 1-device-pixel
#   checkerboard, byte for byte, then closes the window.
#   Positions whose device coordinates are fractional are reported, not expected to pass: the
#   compositor then resamples the whole window. See docs/linux/presentation.md for what Hyprland
#   0.56.2 does to even the integral ones.
#
# Exit 0 when every check passed, 1 when one failed, 77 when the session cannot run it (no
# Wayland display, no binary, no hyprctl/grim/python3 for checkerboard).
set -euo pipefail

mode=offload
seconds=10
while [ $# -gt 0 ]; do
  case "$1" in
    offload | checkerboard) mode=$1 ;;
    --seconds) seconds=$2; shift ;;
    *) echo "usage: $0 [offload|checkerboard] [--seconds N]" >&2; exit 64 ;;
  esac
  shift
done

root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="${TKZMUX_BIN:-$root/.build/debug/tkzmux}"
if [ ! -x "$bin" ]; then
  echo "shell-local.sh: no $bin (swift build --build-system native, or set TKZMUX_BIN)" >&2
  exit 77
fi
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "shell-local.sh: no WAYLAND_DISPLAY: run it inside the desktop session" >&2
  exit 77
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/tkzmux-shell-local.XXXXXX")"
echo "shell-local.sh: traces in $work"

offload() {
  local status=0
  GDK_BACKEND=wayland GDK_DEBUG=offload G_MESSAGES_DEBUG=all WAYLAND_DEBUG=1 \
    "$bin" --presentation-check --expect-dmabuf --seconds "$seconds" > "$work/check.out" 2> "$work/check.err" || status=$?
  grep -E '^(display|compositor|gpu|gpu-warning|geometry|frames|rung|validation|boxes|presentation-check) ' "$work/check.out" || true
  if [ "$status" -ne 0 ]; then
    echo "FAIL: tkzmux --presentation-check exited $status"
    return 1
  fi

  local main sub link
  link=$(grep -m1 -oE 'wl_subcompositor#[0-9]+\.get_subsurface\(new id wl_subsurface#[0-9]+, wl_surface#[0-9]+, wl_surface#[0-9]+\)' \
    "$work/check.err" || true)
  if [ -z "$link" ] || ! grep -qE 'Subsurface .* created' "$work/check.out" "$work/check.err"; then
    echo "FAIL: GDK created no offload subsurface"
    return 1
  fi
  sub=$(sed -E 's/.*wl_surface#([0-9]+), wl_surface#([0-9]+)\)/\1/' <<< "$link")
  main=$(sed -E 's/.*wl_surface#([0-9]+), wl_surface#([0-9]+)\)/\2/' <<< "$link")
  local presents sub_attaches main_attaches creates
  presents=$(grep -m1 '^frames ' "$work/check.out" | grep -oE 'presents=[0-9]+' | cut -d= -f2)
  sub_attaches=$(grep -cE "wl_surface#$sub\.attach\(wl_buffer#" "$work/check.err" || true)
  main_attaches=$(grep -cE "wl_surface#$main\.attach\(wl_buffer#" "$work/check.err" || true)
  # `create` (not Mesa's swapchain `create_immed`): GTK's per-attach import of a frame.
  creates=$(grep -cE ' -> zwp_linux_buffer_params_v1#[0-9]+\.create\(' "$work/check.err" || true)
  echo "subsurface wl_surface#$sub of wl_surface#$main: $sub_attaches dma-buf attaches for $presents frames;" \
    "the main surface (GSK) got $main_attaches; GTK created $creates wl_buffers from dma-bufs"
  local refusals
  refusals=$(grep -hoE '🗙 .*' "$work/check.out" "$work/check.err" | sed -E 's/[0-9.]+ [0-9.]+ [0-9.]+ [0-9.]+/…/' | sort | uniq -c || true)
  [ -n "$refusals" ] && echo "GDK offload refusals:" && echo "$refusals"
  if [ "$sub_attaches" -lt $((presents * 9 / 10)) ]; then
    echo "FAIL: offload did not hold: $sub_attaches of $presents frames reached the subsurface"
    return 1
  fi
  echo "PASS: offloaded"
}

checkerboard() {
  for tool in hyprctl grim python3; do
    command -v "$tool" > /dev/null || { echo "shell-local.sh: checkerboard needs $tool" >&2; return 77; }
  done
  local title="tkzmux presentation-check" output scale failed=0
  output=$(hyprctl monitors -j | python3 -c 'import json,sys; m=[m for m in json.load(sys.stdin) if m["focused"]][0]; print(m["name"], m["scale"], m["x"], m["y"])')
  read -r output scale ox oy <<< "$output"
  echo "output $output scale $scale"
  "$bin" --presentation-check --pattern checkerboard --seconds 120 > "$work/check.out" 2>&1 &
  local pid=$!
  local address=""
  for _ in $(seq 1 100); do
    address=$(hyprctl clients -j | python3 -c 'import json,sys; c=[w for w in json.load(sys.stdin) if w["title"]==sys.argv[1]]; print(c[0]["address"] if c else "")' "$title")
    [ -n "$address" ] && break
    sleep 0.1
  done
  if [ -z "$address" ]; then
    echo "FAIL: the check window never appeared"
    kill "$pid" 2> /dev/null || true
    return 1
  fi
  local window="address:$address"
  dispatch() { hyprctl dispatch "$1" > /dev/null; }
  dispatch "hl.dsp.window.float({ window = \"$window\", action = \"enable\" })"
  dispatch "hl.dsp.window.resize({ window = \"$window\", x = 800, y = 500 })"
  for position in "200 200" "605 400" "333 217"; do
    read -r x y <<< "$position"
    dispatch "hl.dsp.window.move({ window = \"$window\", x = $((ox + x)), y = $((oy + y)) })"
    dispatch "hl.dsp.window.set_prop({ window = \"$window\", prop = \"opacity\", value = \"1 1\" })"
    dispatch "hl.dsp.window.alter_zorder({ window = \"$window\", mode = \"top\" })"
    sleep 0.7
    local at
    read -r -a at <<< "$(hyprctl clients -j | python3 -c 'import json,sys; w=[w for w in json.load(sys.stdin) if w["address"]==sys.argv[1]][0]; print(w["at"][0], w["at"][1], w["size"][0], w["size"][1])' "$address")"
    grim -g "${at[0]},${at[1]} ${at[2]}x${at[3]}" "$work/window.png"
    if ! python3 - "$work/window.png" "$scale" "$ox" "$oy" "${at[@]}" << 'EOF'
import struct, sys, zlib
path, scale, ox, oy, x, y, w, h = sys.argv[1], float(sys.argv[2]), *map(int, sys.argv[3:])
data = open(path, 'rb').read()
pos, idat = 8, b''
while pos < len(data):
    n, = struct.unpack('>I', data[pos:pos + 4]); kind = data[pos + 4:pos + 8]; body = data[pos + 8:pos + 8 + n]; pos += 12 + n
    if kind == b'IHDR': width, height, depth, color = struct.unpack('>IIBB', body[:10])
    elif kind == b'IDAT': idat += body
bpp = {2: 3, 6: 4}[color]; stride = width * bpp; raw = zlib.decompress(idat); rows = []; prev = bytearray(stride); p = 0
for _ in range(height):
    f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
    for i in range(stride):
        a = line[i - bpp] if i >= bpp else 0; b = prev[i]; c = prev[i - bpp] if i >= bpp else 0
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
        elif f == 4:
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(bytes(line)); prev = line
dx, dy = (x - ox) * scale, (y - oy) * scale
integral = dx == int(dx) and dy == int(dy)
cw, ch = round(w * scale), round(h * scale)
assert (width, height) == (cw, ch), f'grim gave {width}×{height}, expected {cw}×{ch}'
bad, seen = 0, {}
for j in range(ch):
    row = rows[j]
    for i in range(cw):
        px = row[i * bpp:i * bpp + 3]
        if px != (b'\xff\xff\xff' if (i ^ j) & 1 else b'\x00\x00\x00'):
            bad += 1
        seen[px] = seen.get(px, 0) + 1
common = ' '.join(f'{k.hex()}×{v}' for k, v in sorted(seen.items(), key=lambda kv: -kv[1])[:3])
verdict = 'byte-exact' if bad == 0 else f'{bad} of {cw * ch} pixels differ'
print(f'window at {x},{y} → device {dx:g},{dy:g} ({"integral" if integral else "fractional"}): {cw}×{ch} {verdict}; most common {common}')
sys.exit(0 if bad == 0 or not integral else 1)
EOF
    then
      failed=1
    fi
  done
  rm -f "$work/window.png"
  dispatch "hl.dsp.window.close({ window = \"$window\" })"
  wait "$pid" || true
  grep -E '^(gpu|geometry|rung|presentation-check) ' "$work/check.out" || true
  [ "$failed" -eq 0 ] && echo "PASS: byte-exact at every integral position" || echo "FAIL: not byte-exact"
  return "$failed"
}

"$mode"
