# Linux performance budgets and measurements

Linux counterpart of the local-only `docs/perf.md`. Each section records what was measured, how, on which machine and when, and the budget where one is set. WOR-313 S1 started the page; WOR-313 S6 adds the frame-encode and GPU-time numbers, and WOR-323 sets the gates (`pixelsWritten`, the <2% and <1 ms budgets, key-to-photon) and decides `VK_LOADER_DRIVERS_SELECT`.

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
