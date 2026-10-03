# Presentation: CanvasHost and the offloaded canvas

How a frame drawn by TkzRenderVK reaches the screen on Linux, written in WOR-314 S4. The renderer side (presentation ring, modifier negotiation, sync_file, buffer age and the fallback ladder) is WOR-313's, documented in `Sources/TkzRenderVK/PresentationRing.swift` and `PresentationLadder.swift`. This page covers the platform side. S5 extends it with the frame clock, damage forwarding and resize.

## The seam: `TkzCanvasHost`

`Sources/TkzCanvasHost` is a Linux-only target with no GTK. The canvas toolkit (TkzCanvasUI, WOR-316) and the app reach the platform only through it. `SourceHygieneTests.theCanvasHostSeamHasNoGtk` keeps imports of CGtk, TkzLinuxShim and TkzGtkShell out of it.

| Type | Role |
|---|---|
| `CanvasHost` | Logical size and scale (`geometry`), `presentationTarget` (formats and `main_device`), `requestFrame`, `present(_:from:)`, the visibility and input streams, and slots for IME, clipboard, popups (WOR-315, WOR-317) and the a11y root (WOR-325) |
| `CanvasHostClient` | `didChangeGeometry` (before the next draw) and `canvasHostDraw` (the host's frame) |
| `CanvasPresenter` | A client's ladder kept at the host's pixel size: acquire, draw, present, hand to the host. It asks for another frame by itself when every image is still held |
| `CanvasFrameQueue` | The pending → shown → previous policy that decides when a slot goes back to its ring |
| `FakeCanvasHost` | Offscreen host for tests. It offers no dma-buf formats, so a presenter on it uses the readback rung, and `shownBytes` holds the pixels on screen. `runFrame()` is its frame clock |
| `GtkCanvasHost` (TkzGtkShell) | The real host, described below |

`Tests/TkzCanvasHostTests` drive the fake host with real ladders: lavapipe in CI, the AMD iGPU locally. They cover idle (no frame without a request), request coalescing, geometry changes reaching the client first, a 20-frame dma-buf run that never starves a ring of three, and a failed import stepping down to readback.

## The window

```text
GtkWindow (decorated = false, CSS class tkzmux-canvas, black)
  └ GtkGraphicsOffload (black_background = true, start-aligned)
      └ TkzCanvas (one texture node per frame)
```

- **CSS** (`CanvasStyle`): one provider per display, at application priority. The window is black and square. The offload widget and the canvas have no background, border, radius, shadow, outline, margin or padding. Any of those would be drawn by GTK, or would make GSK composite instead of offload.
- **Texture**: a `GdkDmabufTexture` with the ring's fourcc (XRGB8888), modifier and planes. It is premultiplied, sRGB, `pixelWidth × pixelHeight`, and appended at the canvas's logical size from (0, 0). A readback frame becomes a `GdkMemoryTexture` (B8G8R8A8 premultiplied).
- **Scale**: from `gdk_surface_get_scale`, never `GDK_SCALE` (ADR-0002 D8). `notify::scale`, `notify::width` and `notify::height` on the surface, and every size_allocate, re-read it, so the client gets the new geometry before the next draw and makes a ring at the new size.
- **GPU**: the presentation target carries the compositor's dmabuf-feedback `main_device`. `VulkanDevice.make(mainDevice:)` then picks the GPU with that DRM node and logs it: `GPU 0: … RADV RAPHAEL_MENDOCINO … its render node is the compositor's main_device 226:129`.

### Whole device pixels (the 5-pixel rule at 1.6)

GTK offloads a texture only when its rect, and the offload widget's black background rect, are whole device pixels. This is `scaled_rect_is_integral` in `gdk/wayland/gdksubsurface-wayland.c` (GTK 4.22.4), which logs `🗙 Non-integral (background) device coordinates` under `GDK_DEBUG=offload`. At scale 1.6 a logical length must be a multiple of 5 to qualify. A tiled 583×646 window failed this check on every frame: GSK composited all 477 frames into the main surface.

So `GtkCanvasHost` snaps the presented size down to whole device pixels (`CanvasGeometry.presentable`: a step of `120 / gcd(scale × 120, 120)` logical pixels, which is 5 at 1.6, 4 at 1.25 and 1 at integer scales). The canvas's measure gives the start-aligned offload widget that same size. The client lays out in the snapped size. The strip left over on the right and at the bottom (under 5 logical pixels, at most 6 device pixels) is the window's black background, drawn once by GSK. After the snap, the same tiled window offloaded every frame. WOR-318 decides whether that strip should take the chrome's colour, which would be one static colour node, or stay black.

### Slots, textures and wl_buffers

- One GdkTexture is built per ring slot and kept. **This does not make GTK reuse `wl_buffer`s.** GTK 4.22.4 creates one per attach (`zwp_linux_buffer_params_v1.create` and a roundtrip waiting for `created`). It destroys that buffer on `wl_buffer.release` and holds a texture reference until then (`get_dmabuf_wl_buffer` and `dmabuf_buffer_release`). Measured over 10 s: 1,194 frames and 1,194 `create`s. The "two ids alternating" seen in the WOR-301 probe were server-side ids being recycled, not reuse. Cutting the per-frame roundtrip would take an own Wayland subsurface (WOR-301's raw-Wayland fallback behind this seam). WOR-323 measures what it costs.
- Keeping the texture still saves rebuilding it. Its reference count is the release signal. `CanvasFrameQueue` releases a slot two shows after it was shown, and `GtkCanvasHost` gives the slot back only once nothing but its own cache refers to the texture: no render node, and no `wl_buffer` the compositor has not released. Until then the slot waits in `draining`, and `deferred-releases` counts the waits. The ring's re-acquire still waits on the dma-buf's implicit fences (WOR-313 S5a).
- If GDK cannot build a texture, the ladder steps down (`importFailed`, logged as an error) and the next frame is drawn on the new rung.

## Checks

| Check | What it shows |
|---|---|
| `tkzmux --presentation-check` | One `GtkCanvasHost` window, a 1-device-pixel checkerboard with a moving bar, a frame every frame-clock tick. It prints the compositor, the GPU and why, the geometry, frame and texture counts, the rung, validation errors, and the box, texture and canvas counts after the window closes. `--pattern checkerboard` presents once and holds. `--readback` forces the readback rung. `--expect-dmabuf` fails on any other rung |
| `PresentationCheckTests` | That check as a subprocess with `TKZMUX_REQUIRE_DISPLAY=1`. It is cancelled without a Vulkan device unless `TKZMUX_REQUIRE_VULKAN=1` |
| `scripts/linux/shell-local.sh offload` | 10 s under `GDK_DEBUG=offload` (+ `G_MESSAGES_DEBUG=all`; `GSK_DEBUG=offload` is rejected) and `WAYLAND_DEBUG=1`. It passes when GDK created the subsurface and the subsurface got at least 90% of the frames' attaches |
| `scripts/linux/shell-local.sh checkerboard` | Hyprland and grim: a floating 800×500 window at three positions, with opacity forced to 1, compared byte for byte with the checkerboard |

### Results on the reference machine (2026-10-03, Hyprland 0.56.2, DP-4 at 1.6, 120 Hz)

- **GPU**: main_device 226:129 was read from the feedback, and the AMD iGPU was chosen because "its render node is the compositor's main_device 226:129".
- **GDK formats**: GDK imports 601 formats, 10 of them XR24. The negotiated ring modifier is `0x020000000056bb03`, with 2 planes and sync_file.
- **Offload**, `shell-local.sh offload`, tiled 583×646 window presented as 580×645 (928×1032 px), 10 s:
  - 1,194 frames, and 1,194 dma-buf attaches on the offload subsurface;
  - 2 attaches on the main surface;
  - 4 textures built, 1,190 reused;
  - 0 deferred releases and 0 validation errors;
  - every texture box finalized after close.
- **Checkerboard**: not byte-exact on Hyprland, and not because of tkzmux:

  | Window position | Device position | Result |
  |---|---|---|
  | 200,200 | 320,320, integral | Every pixel keeps its phase, but black reads 0x010101 and white 0xfefefe. Only the last column is exact |
  | 605,400 | 968,640, integral | The same, with about a fifth of the pixels exact |
  | 333,217 | 532.8,347.2, fractional | Resampled: 0xadadad and 0x515151 |

  `--readback` composites the same frames through GSK into the main surface instead of offloading them, and gives identical numbers. GSK's own black strip reads exactly 0x000000, but a flat colour cannot show a sub-texel shift. The texel mapping is 1:1: the image is 1280×800 for 800×500 at 1.6, and no texel is dropped or doubled. The ±1 is a slight horizontal resampling by the compositor. WOR-322 (in-app readback is the parity gate, ADR-0003 §4) and WOR-323 follow it up. Hyprland's `render:cm_enabled` was not toggled on the user's session.

### Not verified here

- Headless sway: in this session sway is SIGKILLed at start-up, even with an empty config. Under sway's pixman renderer the check would use the readback rung, because there are no dma-buf formats. The asan-valgrind CI job has no Vulkan driver, so it cancels `PresentationCheckTests`.
- GTK 4.16: everything here is 4.14 or 4.16 API (`gtk_graphics_offload_set_black_background`, `gdk_dmabuf_texture_builder_set_color_state`). `notify::scale` on the surface needs 4.12.
