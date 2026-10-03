# Linux performance budgets and measurements

Linux counterpart of the local-only `docs/perf.md`. Each section records what was measured, how, on which machine and when, and the budget where one is set. WOR-313 S1 started the page; WOR-313 S6 added the frame-encode and GPU-time numbers, and WOR-323 sets the gates (`pixelsWritten`, the <2% and <1 ms budgets, key-to-photon) and decides `VK_LOADER_DRIVERS_SELECT`.

## Reference machine

AMD Ryzen 9 9950X, its integrated Radeon (RADV RAPHAEL_MENDOCINO, `card2`, `boot_vga=1`, primary 226:2, render 226:129, the compositor's dmabuf-feedback `main_device`), and an NVIDIA RTX 5060 (`card1`, primary 226:1, render 226:128). Arch/Omarchy, kernel 7.2.5, Mesa 26.2.2, NVIDIA 610.57.04, Vulkan loader 1.4.357 with Mesa's `device_select` implicit layer, Hyprland 0.56.2.

## GPU start-up: `vkCreateInstance` (WOR-313 S1)

The loader reads every ICD manifest and loads each driver inside `vkCreateInstance`, so its cost depends on which drivers are installed, not on tkzmux. Measured 2026-10-03 with the release `tkzmux-vtdump gpu --no-validation --no-clear --headless`, which times the call alone with `Clocks.monotonicNanos`. Each row is 21 separate processes, so every sample is a cold instance in a fresh process (driver files in the page cache).

| Drivers the loader sees | How | median | min | max |
|---|---|---|---|---|
| RADV + NVIDIA (the default) | nothing set | 6.80 ms | 6.54 ms | 7.81 ms |
| RADV only | `VK_LOADER_DRIVERS_SELECT='*radeon*'` | 0.74 ms | 0.70 ms | 0.77 ms |
| RADV only | `VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json` | 0.69 ms | 0.67 ms | 0.81 ms |
| NVIDIA only | `VK_LOADER_DRIVERS_SELECT='*nvidia*'` | 3.19 ms | 3.03 ms | 6.28 ms |
| RADV + NVIDIA, no `device_select` | `VK_LOADER_LAYERS_DISABLE='*device_select*'` | 3.71 ms | 3.52 ms | 4.08 ms |
| lavapipe only (Arch `vulkan-swrast` 26.2.2) | `VK_DRIVER_FILES=<lvp_icd.json>` | 0.65 ms | 0.64 ms | 0.76 ms |

- Selecting the iGPU's driver alone saves about 6 ms of start-up. Of the default 6.8 ms, RADV accounts for about 0.7 ms, loading the NVIDIA driver for about 3 ms, and `device_select` for about 3 ms more, because with two devices it enumerates and sorts them inside `vkCreateInstance`.
- `device_select` is also what makes loader order put the iGPU first. With it disabled, the RTX 5060 enumerates first and `tkzmux-vtdump gpu` (which has no `main_device`) selects it. The app does not depend on that order once WOR-314 S4 feeds the compositor's `main_device` to `DeviceSelector`.
- The debug build gives the same numbers (6.82 ms default, 0.83 ms RADV only): the time is spent in the loader and drivers.
- With `VK_LAYER_KHRONOS_validation` loaded (Arch `vulkan-validation-layers` 1.4.357) it took 12.0 ms with three drivers (RADV, NVIDIA, lavapipe) and 2.5-3.1 ms with lavapipe alone (single runs). Validation is on in tests and CI only.
- No budget is set here. Whether tkzmux sets `VK_LOADER_DRIVERS_SELECT` itself, from the `main_device` it already knows, is WOR-323's decision.

To repeat a row:

```sh
vtdump="$(swift build --build-system native -c release --show-bin-path)/tkzmux-vtdump"
for i in $(seq 21); do
  VK_LOADER_DRIVERS_SELECT='*radeon*' "$vtdump" gpu --no-validation --no-clear --headless 2>/dev/null \
    | sed -n 's/.*vkCreateInstance \([0-9.]*\) ms.*/\1/p'
done | sort -n | awk '{ a[NR] = $1 } END { print "median", a[int((NR + 1) / 2)], "ms" }'
```

## Frame encode and GPU time (WOR-313 S6)

`tkzmux-vtdump bench-frame` on Linux draws through `VulkanTerminalRenderer` into an offscreen `B8G8R8A8_UNORM` target. Every measured frame re-attaches the surface, so each one is a `DIRTY_FULL` rebuild of every row (the worst case: a session switch or a scroll). It reports:

- `build`: `FrameBuilder.update`, shared with the Mac (TkzRenderCore).
- `encode`: the Vulkan renderer's CPU half: the instance writes, recording the four passes, and `vkQueueSubmit2`.
- `gpu`: the GPU time of the frame, from a timestamp-query pair around everything the frame records (`GPUFrameTimer`: the atlas upload when there is one, then the four passes). Each frame is waited for before the next.

`--size <w>x<h>` sets the target size; the grid then fills it with whole cells and the rest is letterbox. Measured 2026-10-03, release build, validation off, the default `text` corpus, 20 warm-up and 200 measured frames, three runs per row on RADV (ranges are across the runs).

| Device | Target | Grid | build median | encode median (p99) | GPU median (p99) |
|---|---|---|---|---|---|
| RADV (iGPU) | 3400×2220 (scale 2) | 200×60 | 1.00–1.04 ms | **0.067–0.071 ms** (0.11–0.33) | 1.64 ms (1.65–1.69) |
| RADV (iGPU) | **7680×2160** (scale 2) | 451×58 | 1.73–1.76 ms | 0.075–0.077 ms (0.13–0.14) | **3.77–3.81 ms** (4.03–4.08) |
| RADV (iGPU), `--fill blank` | 7680×2160 (scale 2) | 451×58 | 1.38 ms | 0.056 ms | 3.31 ms (3.96) |
| RADV (iGPU) | 7680×2160 (scale 1.6) | 548×72 | 2.57 ms | 0.087 ms (0.14) | 3.96 ms (4.02) |
| RTX 5060 (`TKZMUX_GPU=discrete`) | 7680×2160 (scale 2) | 451×58 | 1.75 ms | 0.73 ms (0.91) | 0.16 ms (0.16) |
| lavapipe (50 frames) | 7680×2160 (scale 2) | 451×58 | 1.84 ms | 0.060 ms (0.11) | 5.53 ms (7.08) |

- A full-dirty 200×60 frame records in 0.07 ms of CPU on the 9950X, against the S6 target of < 0.5 ms. `build` (FrameBuilder over every row, 2545 glyphs) adds about 1 ms; it is the same code on the Mac.
- The 7680×2160 frame costs 3.8 ms of GPU time on the iGPU. Most of it is fill: a blank screen at the same size costs 3.3 ms, since the render area's `LOAD_OP_CLEAR` and the background pass each write all 16.6 Mpx. The text passes add about 0.5 ms. The idle guarantee and the presentation ring's damage copies (S4b, S5b) mean a frame pays this only when the whole window is redrawn.
- The RTX 5060's `encode` (0.73 ms) is ten times RADV's for the same code. It was not broken down here; WOR-323 owns the frame budgets.
- No budget is set here; WOR-323 sets the gates (the < 1 ms and < 2 % budgets, `pixelsWritten`, in-app GPU timestamps).

To repeat a row:

```sh
vtdump="$(swift build --build-system native -c release --show-bin-path)/tkzmux-vtdump"
"$vtdump" bench-frame --cols 200 --rows 60
"$vtdump" bench-frame --size 7680x2160              # add --fill blank, --scale 1.6
TKZMUX_GPU=discrete "$vtdump" bench-frame --size 7680x2160
```
