# ADR-0005: Window controls, header strip and the Hyprland snippet policy

- **Status:** Accepted, provisional on WOR-301 S6
- **Date:** 2026-10-02 (written in WOR-299 S5, ratified in WOR-299 S6)
- **Issue:** WOR-299 S5 (M0 gate)
- **Implemented by:** WOR-314 (S3 snippet files, S6 `WindowControlsModel`, move/resize, multi-toplevel), WOR-315 S3 (colliding-bind table in `docs/linux/input.md`), WOR-318 (header composition, drawing the controls), WOR-319 S6 (Settings window, float-rule check), WOR-322 (L0/L6 exclusion), WOR-324 S2 (bypass lines, hyprlang variant, install)
- **Finalized by:** WOR-301 S6. It fills the [open fields](#open-fields-filled-by-wor-301-s6) and amends this header to `Accepted (final)`, or records the fallback here.
- **Applies:** user decisions 1, 5 and 7 in [decisions.md](decisions.md), and the WOR-299 S6 verdicts on SUPER+digits and the `terminal` tag
- **Related:** [ADR-0001](adr-0001-charter.md) (GTK never draws a visible pixel), [ADR-0002](adr-0002-platform-defaults.md) (GTK 4.16 floor, `dlsym` for newer APIs, app-id), [ADR-0003](adr-0003-parity.md) (L0 exclusion, `windowControls` mask), [ADR-0004](adr-0004-keys-input.md) (Super as ⌘, fallback table, reserved chords), [index](README.md)

## Context

1. **User decision 7 (2026-10-02).** Hyprland comes first, and the window should feel like a Linux app. There are no Mac traffic lights. Native window controls appear where the desktop expects them, honouring `gtk-decoration-layout` and xdg_toplevel `wm_capabilities`. Everything inside the window matches the Mac. Other compositors are best effort.
2. **User decision 1.** GTK4 is only the platform shell and never draws a visible pixel. tkzmux therefore cannot use a GtkHeaderBar, GtkWindowControls or GTK's client-side decoration (CSD) shadow. The controls are tkzmux pixels driven by GDK calls.
3. **The Mac header today.** The main window is `.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView` (`Sources/TkzApp/MainWindowController.swift:532`). It has a transparent `.unifiedCompact` titlebar (`MainWindowController.swift:734-738`), and `ChromeViewController` paints its own header strip under it (`Sources/TkzApp/ChromeViewController.swift:1-11`). The strip:
   - is exactly the titlebar plus toolbar safe-area height (`ChromeViewController.swift:114-119`);
   - has a 1 pt bottom border in `theme.border` (`ChromeViewController.swift:45-48,57-59`);
   - moves the window from its empty pixels (`ChromeViewController.swift:55`).

   The toolbar items are `[flexibleSpace, title, flexibleSpace, run, viewCluster]`, with the title centred on the window (`Sources/TkzApp/Toolbar/MainToolbarController.swift:164,321`). The traffic lights sit at the leading edge. The minimum size is 720×420 and the default size 1240×820 (`MainWindowController.swift:328-329`). Closing the last window quits the app (`Sources/TkzApp/AppDelegate.swift:171-173`).

   The `Theme.titlebar` comment still says 48 pt (`Sources/TkzCore/Theme.swift:37`). That number predates the compact chrome of b3c998e: the real height is the measured safe-area inset.
4. **The Mac Settings window.** It is `.titled, .closable, .fullSizeContentView`, titled "Settings", with zoom disabled (`Sources/TkzApp/Settings/SettingsWindowController.swift:219-230`). It is fixed at 720×600 (`Sources/TkzApp/Settings/SettingsView.swift:17-18`), and its traffic lights sit in the nav column's top-left (`SettingsView.swift:153-154`).
5. **What GDK offers** (GTK 4.22.4 headers on the target machine; floor 4.16 per ADR-0002):
   - `gdk_toplevel_show_window_menu`, `begin_resize` and `begin_move` exist in every 4.x (`/usr/include/gtk-4.0/gdk/gdktoplevel.h:188,209,218`).
   - `gdk_toplevel_titlebar_gesture` exists since 4.4 (`gdktoplevel.h:225-226`).
   - `GdkToplevelCapabilities` and `gdk_toplevel_get_capabilities` are 4.20 only (`gdktoplevel.h:305-318`). The bits are EDGE_CONSTRAINTS, INHIBIT_SHORTCUTS, TITLEBAR_GESTURES, WINDOW_MENU, MAXIMIZE, FULLSCREEN, MINIMIZE and LOWER.
6. **What the protocol says.** xdg_toplevel `wm_capabilities` (xdg_wm_base v5) lists `window_menu`, `maximize`, `fullscreen` and `minimize`. "If a capability isn't supported, clients should hide or disable the UI elements that expose this functionality", and the compositor ignores requests it does not support (https://wayland.app/protocols/xdg-shell). Close is not a capability: closing is the client's own action.
7. **`gtk-decoration-layout`.** It lists buttons left and right of a colon. Recognised names are `minimize`, `maximize`, `close`, `icon` and `menu`. GTK's compiled-in default is `menu:minimize,maximize,close` (https://docs.gtk.org/gtk4/property.Settings.gtk-decoration-layout.html). On the target machine `gsettings get org.gnome.desktop.wm.preferences button-layout` returns `'appmenu:close'`.
8. **Hyprland v0.56.2 (efb50993).**
   - **No title bars, and no window menu.** It implements xdg-decoration but draws no title bar (research `ui-architecture-options` finding 21; https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/CMakeLists.txt). Its xdg_toplevel sends `wm_capabilities` with only FULLSCREEN and MAXIMIZE, and it has no `show_window_menu` handler (https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/src/protocols/XDGShell.cpp).
   - **The inhibitor stops every bind.** While a keyboard-shortcuts inhibitor is active, `handleKeybinds` skips every bind that lacks `dontInhibit` (the `p`/bypass flag), unless `binds:disable_keybind_grabbing` is set (https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/src/managers/KeybindManager.cpp). This covers mouse binds (`mouse:272`), media keys, PRINT, ALT+TAB and CTRL+ALT+DELETE, not only Super chords. *Read from source; WOR-301 S6 confirms it at runtime.*
9. **Omarchy (omarchy-settings 4.0.4-1)** changes the window in three ways that matter here:
   - **Default opacity.** Every window is tagged `+default-opacity` (`/usr/share/omarchy/default/hypr/windows.lua:6`). App rules may remove that tag (`windows.lua:21-22`), and afterwards `opacity = "0.985 0.96"` is applied to every window still carrying it (`windows.lua:25`). Maximize events are suppressed for all windows (`windows.lua:3`).
   - **The `terminal` tag drives SUPER+C/V.** The tag is defined by an app-id regex that does not match `se.tkz.tkzmux` (`/usr/share/omarchy/default/hypr/apps/terminals.lua:5-8`). SUPER+C and SUPER+V inject Ctrl+Insert and Shift+Insert into windows with the tag, and Ctrl+C and Ctrl+V into windows without it. SUPER+X always injects Ctrl+X (`/usr/share/omarchy/default/hypr/bindings/clipboard.lua:45-47`). Ctrl+C is SIGINT, or a Claude Code interrupt (research `input-keyboard-shortcuts` verdict correction 5).
   - **Themes key opacity on the tag.** Kanagawa sets `opacity = "0.99 0.985"` on it (`/usr/share/omarchy/themes/kanagawa/hyprland.lua:18`). No other shipped theme and no other default file references the tag (grep of `/usr/share/omarchy/themes/*/hyprland.lua` and `default/hypr/**`).
   - **Load order.** The theme loads last inside `default.hypr.omarchy` (`/usr/share/omarchy/default/hypr/omarchy.lua:19-22`). The user files load after it (`~/.config/hypr/hyprland.lua:14-23`). The user's `~/.config/hypr/bindings.lua` has no active binds (all lines are comments).
10. **Why this was open.** The research left window decorations open, and all three judges asked the user about traffic lights and desktop scope. They also asked for the window-rule snippet to land with the first window, not with packaging (research `judgments[0..2]`, grafts 7/8/8).

## Decision

### 1. No traffic lights, and GTK draws no decorations

- **No traffic lights.** Every toplevel is created with `gtk_window_set_decorated(FALSE)`, and its single TkzCanvas fills it. GTK draws no title bar, no CSD shadow and no resize margin. The canvas stays opaque and unclipped at (0,0), which GraphicsOffload requires (ADR-0001).
- **Controls are tkzmux pixels.** The minimize, maximize/restore and close glyphs are flat symbolic glyphs drawn from theme tokens, with hover and pressed states. They are not coloured circles, so they do not mimic macOS. WOR-318 owns the exact metrics and tokens. WOR-314 S6 owns `WindowControlsModel`, the hit-test seam and the GDK calls.
- **A button is drawn only if it appears in `gtk-decoration-layout` *and* the toplevel allows it.**
  - **Layout.** Parse `GtkSettings:gtk-decoration-layout` (read through GObject, with live `notify::` updates) into left and right lists. Keep `minimize`, `maximize` and `close`. Ignore `appmenu`, `menu`, `icon` and unknown tokens: tkzmux has no app menu or window icon to put there. Keep the order and the side the layout gives.
  - **Capabilities.** `minimize` needs `GDK_TOPLEVEL_CAPABILITIES_MINIMIZE`, and `maximize` needs `..._MAXIMIZE`. `close` needs no capability, and is dropped only when the layout omits it.
  - **Without the 4.20 symbol, close only.** `gdk_toplevel_get_capabilities` is resolved at run time through the TkzLinuxShim `gtk_get_minor_version()` + `dlsym` helper (ADR-0002). On GTK 4.16–4.19, where the symbol is missing, the model shows close only, wherever the layout puts it.
  - **Live updates.** The model is recomputed when the layout setting changes and when the toplevel's capabilities or state change.
- **Button actions.**
  - Close calls `gtk_window_close`. It has the Mac red light's semantics: closing the main window quits the app (`AppDelegate.swift:171-173`), and closing Settings hides it.
  - Minimize calls `gtk_window_minimize`.
  - Maximize toggles `gtk_window_maximize`/`unmaximize`. Its glyph shows restore while the window is maximized.
  - Fullscreen gets no button. On the Mac, fullscreen is the green light's job. On Linux the convention is maximize, and fullscreen stays with the compositor (SUPER+F is claimed by tkzmux, see section 4).
- **Header pointer gestures.** The hit-test seam returns one of `.control(kind)`, `.interactive` (title, Run, view cluster), `.move` (empty header pixels) or `.resize(edge)`.
  - **Move.** A primary-button drag on `.move` calls `gdk_toplevel_begin_move` with the event's device, button, position and timestamp. This mirrors `mouseDownCanMoveWindow` (`ChromeViewController.swift:55`).
  - **Double-, middle- and right-click** on `.move` call `gdk_toplevel_titlebar_gesture` with the matching gesture. It returns FALSE when the compositor cannot handle the gesture (only Mutter has the gtk-shell path). tkzmux then performs the action that the GtkSettings `gtk-titlebar-double-click`, `gtk-titlebar-middle-click` or `gtk-titlebar-right-click` value names (double-click defaults to `toggle-maximize` and right-click to `menu`; https://docs.gtk.org/gtk4/property.Settings.gtk-titlebar-double-click.html), gated as follows:
    - `menu` calls `gdk_toplevel_show_window_menu`, only when WINDOW_MENU is present;
    - `toggle-maximize` needs MAXIMIZE;
    - `minimize` needs MINIMIZE;
    - `lower` needs LOWER;
    - otherwise nothing happens.

    On GTK below 4.20 the gate assumes nothing: only `menu` is attempted, and only through `show_window_menu`'s own return value.
- **Resize edges.** tkzmux hit-tests the edges itself and calls `gdk_toplevel_begin_resize` with the matching `GdkSurfaceEdge`.
  - **Size.** The band is 8 logical px wide, inside the window (there is no shadow margin to put it in), with corners where two bands meet.
  - **When the band is live.** An edge is live only when the window is not maximized or fullscreen, and either it is not tiled on that side or the per-edge `*_RESIZABLE` state allows it (EDGE_CONSTRAINTS). The band shows the matching resize cursor.
  - **Clicks.** Edge hits take precedence over `.interactive` only where no control sits under the pointer.
  - **Minimum size.** The minimum stays 720×420 logical (`MainWindowController.swift:329`).

### 2. The header strip

- **Otherwise identical to the Mac.** The height is the Mac's measured `.unifiedCompact` safe-area inset (WOR-307 measures it and freezes it as a token). The background is the `titlebar` token, flattened and opaque, with the 1 pt `theme.border` bottom line (ADR-0003 substitutes for the `.sidebar` vibrancy). The title, the ▶ Run split control and the four-segment view cluster keep the Mac's layout. The title stays centred on the window width, as `centeredItemIdentifiers` centres it.
- **The controls zone.** This is the smallest rect that holds the buttons the model shows on one side, plus their outer inset. It is reserved on that side of the header and nothing else is placed in it. When the zone is on the trailing side, the Run control and the view cluster are anchored to the zone's leading edge instead of the window's trailing edge. When the layout puts nothing on the leading side, the area where the Mac's traffic lights sit is left as plain header background.
- **Parity.** The controls zone is excluded from the L0 comparison, and the Mac's traffic-light zone is excluded likewise. In L0, trailing header items are compared by their offset from their anchor: the window's trailing edge on the Mac, and the trailing controls zone's leading edge on Linux. L6 uses the `windowControls` mask over both zones (ADR-0003).
- **Settings gets close only.** The Settings toplevel (WOR-319 S6, built on WOR-314 S6's multi-toplevel helper) is transient for the main window, fixed at 720×600 and not resizable. Its xdg title is exactly `Settings` (the Mac's `window.title`, `SettingsWindowController.swift:223`). Its model shows only `close`, on the side the layout gives. If the layout has no `close`, Settings shows no button and closes with Esc or Super+W, as on the Mac (`docs/shortcuts.md:27`). The nav column keeps the Mac's top inset; the traffic-light spot in its top-left stays empty.
- **No Linux-only chrome.** There is no app-menu button, no window icon and no Linux-only toolbar item. Minimize and Hide keep their ADR-0004 verdicts: ⌘M, ⌘H and ⌥⌘H stay unbound on Linux (`Sources/TkzApp/MainMenu.swift:194-201,298`).

### 3. Behaviour per desktop

| | Hyprland 0.56.2 (Omarchy) — first-class | GNOME (Mutter, Wayland only since GNOME 50) — best effort | KDE (KWin) — best effort |
|---|---|---|---|
| Server-side title bar | None | None (Mutter has no xdg-decoration) | None expected: GTK asks for client-side mode when `decorated=FALSE` *(inferred)* |
| Capabilities (4.20) | FULLSCREEN, MAXIMIZE from `wm_capabilities`; no WINDOW_MENU, no MINIMIZE (XDGShell.cpp) | All four `wm_capabilities` expected, plus TITLEBAR_GESTURES through gtk-shell *(inferred)* | All four `wm_capabilities` expected *(inferred)* |
| Typical layout | `appmenu:close` (gsettings on this machine) | `appmenu:close` (GNOME default) | Mirrors the KWin button order through the settings portal, e.g. `icon:minimize,maximize,close` *(inferred)* |
| Buttons drawn | Close, trailing | Close, trailing | Minimize, maximize, close, trailing; `icon` ignored |
| Header drag | `begin_move`. Floating windows move; on tiled windows Hyprland decides (WOR-314 S6 records it) | `begin_move` | `begin_move` |
| Double-click | `titlebar_gesture` returns FALSE, so `toggle-maximize` runs. It is a no-op on Omarchy (`windows.lua:3` suppresses maximize) and maximizes on plain Hyprland | Mutter handles the gesture | Fallback action per GtkSettings |
| Right-click | No window menu, so nothing happens | Mutter's window menu | `show_window_menu` (KWin menu) |
| Resize edges | Floating windows only; tiled windows are sized by the layout | All edges, except tiled or maximized ones | All edges, except tiled or maximized ones |
| Shadow | None (Hyprland draws its own border and rounding) | None: tkzmux draws no CSD shadow, so the window looks flat | None |

WOR-314 S6 runs a non-gating smoke on nested or headless Mutter and KWin and records what it sees in `docs/linux/hyprland.md`. The *inferred* cells are made final from that smoke.

### 4. Hyprland snippet policy

WOR-314 S3 applies this policy in `packaging/linux/hyprland/` and `docs/linux/hyprland.md`, WOR-319 S6 verifies the Settings rule, and WOR-324 S2 adds the bypass lines, the hyprlang variant and the install step. Those issues apply the policy; they do not re-decide it.

- **Match.** Every rule matches the class `^se\.tkz\.tkzmux(\.Devel)?$` (release and debug app-ids, ADR-0002).
- **Load order.** The snippet must load after `require("default.hypr.omarchy")`, so that it comes after Omarchy's defaults *and* the current theme (`omarchy.lua:19-22`). In practice that means the end of `~/.config/hypr/hyprland.lua`, or a file required from it. `docs/linux/hyprland.md` states this.
- **Opacity.** Remove the tag with `tag = "-default-opacity"`, and also set `opacity = "1 1"` in a later rule. Both are needed: the opacity rule at `windows.lua:25` is ordered before the user's files, and the terminal tag below brings theme opacity rules with it. The policy is met only when `hyprctl clients -j` reports no `default-opacity` tag and an effective alpha of 1.0 for the class, under both the default theme and kanagawa (WOR-314 S3, WOR-324 S2).
- **Settings floats.** Match the class plus the title `^Settings$` with `float` and `center`. The main window's title must never be `Settings`.
- **The `terminal` tag: apply it (`tag = "+terminal"`).** This is the decision, ratified in WOR-299 S6 (2026-10-02); WOR-301 S6 revisits it with measured inputs.
  - **The tag only matters in fallback mode.** With the inhibitor granted, SUPER+C and SUPER+V never reach Omarchy's bind; tkzmux receives them as ⌘C and ⌘V. The tag decides what happens when the inhibitor is denied, revoked or not supported, or when a user bypasses those binds.
  - **With the tag,** Omarchy injects Ctrl+Insert and Shift+Insert, which are tkzmux's copy and paste-CLIPBOARD chords in every mode (ADR-0004). Without it, SUPER+C injects Ctrl+C (SIGINT) into the focused agent, and SUPER+V injects Ctrl+V, Claude Code's image-paste key. WOR-324's acceptance ("with inhibit inactive, SUPER+C/V never send SIGINT") cannot be met without the tag.
  - **Cost.** Theme rules keyed on the tag apply (kanagawa 0.99/0.985). The snippet's later `opacity = "1 1"` rule counters them, and the alpha check above verifies it. No other Omarchy default reads the tag.
  - **Residual gap.** SUPER+X injects Ctrl+X whatever the tag (`clipboard.lua:47`). With the inhibitor granted, tkzmux claims Super+X and drops it, because unmatched Super chords are dropped (ADR-0004). In fallback mode, Ctrl+X (0x18) reaches the terminal. This is recorded in `docs/linux/hyprland.md`, not worked around.
- **Bypass verdicts.** Because the inhibitor silences every Hyprland bind (Context 8), the snippet must actively give back every WM bind that tkzmux does not claim. A *claim* means tkzmux receives the chord while it is focused and the inhibitor is granted; that WM bind is dead over tkzmux. A *bypass* means the snippet marks the bind with Hyprland's bypass flag (hyprlang `bindp`; in Lua the `dont_inhibit` bind option, `/usr/share/hypr/stubs/hl.meta.lua:437-444`; WOR-324 S2 confirms that mouse and temporary binds accept it); tkzmux never sees the chord. Without the inhibitor, every bind behaves as stock Omarchy and these verdicts have no effect. WOR-315 S3 turns the table below into the colliding-bind table in `docs/linux/input.md`, and WOR-324 S2 turns that into lines.

#### Verdicts for every Omarchy bind

Collisions are computed against the Linux table: the Mac defaults with ⌘ as Super and ⌥ as left Alt (`Sources/TkzApp/Menus/ShortcutsTable.swift:194-229`), plus ⌘C, ⌘V and ⌘Q, Super-hold for the cheat sheet, and Super+click for links (ADR-0004; `Sources/TkzTerminalView/MouseController.swift:392-399`). "code:N" binds are physical keys; on `us`, code:20/21 are `-`/`=`, code:34/35 are `[`/`]`, and code:10–19 are 1–0.

**Claimed by tkzmux (collisions; the WM bind is dead while tkzmux has focus):**

| Omarchy bind (file) | Omarchy action | tkzmux action |
|---|---|---|
| SUPER+W (tiling.lua:1) | Close window | `closeTerminal` ⌘W. The window still closes through its close button or ⌘Q |
| SUPER+T (tiling.lua:6) | Float toggle | `newTerminal` ⌘T |
| SUPER+F (tiling.lua:7) | Fullscreen | `searchSessions` ⌘F |
| SUPER+O (tiling.lua:10) | Pop window out | `openFolder` ⌘O |
| SUPER+ALT+LEFT/RIGHT/UP/DOWN (tiling.lua:76-79) | Move into group | `focusPane*` ⌥⌘arrows |
| SUPER+CTRL+code:21 (tiling.lua:63) | Shrink window left a lot | `equalizeSplits` ⌃⌘=. On `se` the key is `´`, so ADR-0004's physical-key match applies |
| SUPER+mouse:272 (tiling.lua:70) | Drag-move window | Super+click on links (ADR-0004). Ctrl+click stays an alias, and header drag still moves the window. Final once WOR-301 S6 measures mouse-bind inhibition |
| SUPER+SHIFT+RETURN (applications.lua:3) | Browser | `zoomPane` ⇧⌘↩ |
| SUPER+SHIFT+N (applications.lua:8) | Editor | `newGroup` ⇧⌘N |
| SUPER+SHIFT+D (applications.lua:16) | Docker TUI | `splitHorizontally` ⇧⌘D |
| SUPER+SHIFT+G (applications.lua:17) | Signal | `showChanges` ⇧⌘G |
| SUPER+SHIFT+W (applications.lua:19) | Omawrite | `closeSession` ⇧⌘W |
| SUPER+SHIFT+C (applications.lua:24) | Calendar | `copyLastMessage` ⇧⌘C |
| SUPER+SHIFT+P (applications.lua:30) | Google Photos | `commandPalette` ⇧⌘P |
| SUPER+C, SUPER+V (clipboard.lua:45-46) | Universal copy/paste | ⌘C copy, ⌘V paste |
| SUPER+X (clipboard.lua:47) | Universal cut (Ctrl+X) | Dropped as an unmatched Super chord, so Ctrl+X is never injected |
| SUPER+comma (utilities.lua:24) | Dismiss last notification | `settings` ⌘, |
| SUPER+CTRL+R (utilities.lua:88) | Set reminder | `runDevServer` ⌃⌘R |

**SUPER+1…9 (tiling.lua:20-22, `SUPER + code:10…18`, workspaces 1–9): claimed by tkzmux.** They collide with `selectSession(1…9)` ⌘1–9. Decided in WOR-299 S6 (2026-10-02) under the user's delegation ([decisions.md](decisions.md), S6-2):
- **Default: claim.** While tkzmux is focused and the inhibitor is granted, Super+1–9 select sessions exactly as ⌘1–9 do on the Mac, and Omarchy's workspace switch is silenced for those nine binds. SUPER+0 (`code:19`, workspace 10) has no tkzmux chord and is bypassed (list below), as are SUPER+SHIFT+digits and SUPER+SHIFT+ALT+digits (move window to workspace).
- **Opt-out, documented, not shipped.** A user who wants workspace switching to keep working over tkzmux marks SUPER+1–9 with the bypass flag (`bindp`, or `dont_inhibit = true` in Lua). tkzmux then never sees Super+1–9 while that line is in place; sessions stay reachable from the sidebar, the palette (⇧⌘P) and ⇧⌘U. `docs/linux/hyprland.md` (WOR-314 S3, WOR-324 S2) gives the exact lines and says that the cheat sheet keeps the ⌘1–9 hints, which are shadowed while the bypass is in place.
- **Not chosen:** bypassing SUPER+1–0 by default (the S5 draft's recommendation). It keeps workspace switching but drops the Mac's ⌘1–9 session switching whenever tkzmux has focus; the opt-out gives that result to anyone who prefers it.

**SUPER+RETURN (applications.lua:2, terminal): bypass.** Outside overlays tkzmux has no Super+Return chord. Inside the search overlay, ⌘↵ runs the Actions row (`docs/shortcuts.md:83`); a bypassed SUPER+RETURN cannot reach it, so the overlay also accepts Ctrl+Enter in both modes (ADR-0004 §3.3).

**SUPER+SHIFT+comma (utilities.lua:25, dismiss all notifications): bypass for now.** It collides only with `reloadConfig` ⇧⌘,, which is reserved, hidden and has no handler (`docs/shortcuts.md:29`). It becomes a claim, with a snippet change, in the same PR that gives `reloadConfig` a handler.

**Bypassed (no tkzmux chord, so the WM keeps them).** Every other Omarchy bind:
- **tiling.lua:**
  - SUPER+J, SUPER+P, SUPER+CTRL+F, SUPER+ALT+F, SUPER+ALT+Home, SUPER+Home, SUPER+L;
  - SUPER+LEFT/RIGHT/UP/DOWN;
  - SUPER+code:19 (workspace 10; tkzmux has no ⌘0); SUPER+SHIFT+code:10–19; SUPER+SHIFT+ALT+code:10–19;
  - SUPER+S, SUPER+ALT+S, SUPER+TAB, SUPER+SHIFT+TAB, SUPER+CTRL+TAB;
  - SUPER+SHIFT+ALT+arrows, SUPER+SHIFT+arrows;
  - SUPER+code:20/21 with no modifier, with SHIFT, with ALT, with SHIFT+ALT, with CTRL+SHIFT, and SUPER+CTRL+code:20;
  - SUPER+mouse_down/up, SUPER+mouse:273, SUPER+G, SUPER+ALT+G, SUPER+ALT+TAB, SUPER+ALT+SHIFT+TAB, SUPER+CTRL+LEFT/RIGHT, SUPER+ALT+mouse_down/up;
  - SUPER+ALT+code:10–14, SUPER+SLASH, SUPER+ALT+SLASH.
- **applications.lua:**
  - SUPER+SHIFT+F, SUPER+ALT+SHIFT+F, SUPER+SHIFT+B, SUPER+SHIFT+ALT+B;
  - SUPER+ALT+RETURN, SUPER+CTRL+RETURN, SUPER+SHIFT+M, SUPER+SHIFT+ALT+M;
  - SUPER+SHIFT+O, SUPER+SHIFT+SLASH, SUPER+SHIFT+A, SUPER+SHIFT+ALT+A;
  - SUPER+SHIFT+E, SUPER+SHIFT+ALT+E, SUPER+SHIFT+Y, SUPER+SHIFT+ALT+G, SUPER+SHIFT+CTRL+G;
  - SUPER+SHIFT+S, SUPER+SHIFT+X, SUPER+SHIFT+ALT+X.
- **clipboard.lua:** SUPER+CTRL+V.
- **utilities.lua:**
  - SUPER+SPACE, SUPER+ALT+SPACE, SUPER+CTRL+E, SUPER+CTRL+C, SUPER+CTRL+O, SUPER+CTRL+H;
  - SUPER+SHIFT+code:201, SUPER+ESCAPE;
  - SUPER+K, SUPER+ALT+K, SUPER+CTRL+K, SUPER+CTRL+Q;
  - SUPER+SHIFT+SPACE, SUPER+CTRL+SPACE, SUPER+SHIFT+CTRL+SPACE;
  - SUPER+BACKSPACE, SUPER+SHIFT+BACKSPACE, SUPER+CTRL+BACKSPACE;
  - SUPER+CTRL+comma, SUPER+ALT+comma, SUPER+SHIFT+ALT+comma, SUPER+CTRL+I, SUPER+CTRL+N, SUPER+CTRL+Delete, SUPER+CTRL+ALT+Delete;
  - SUPER+PRINT, SUPER+CTRL+PRINT, SUPER+ALT+code:34/35, SUPER+CTRL+S, SUPER+CTRL+PERIOD;
  - SUPER+CTRL+ALT+R, SUPER+SHIFT+CTRL+R, SUPER+CTRL+ALT+T/B/W, SUPER+SHIFT+CTRL+A;
  - SUPER+CTRL+A/B/D/W/P/T, SUPER+CTRL+ALT+D, SUPER+CTRL+code:10–18, SUPER+CTRL+Z, SUPER+CTRL+ALT+Z, SUPER+CTRL+L.
- **voxtype.lua:** SUPER+CTRL+X.
- **Non-Super binds**, which the inhibitor also silences:
  - CTRL+ALT+DELETE, ALT+TAB, ALT+SHIFT+TAB, CTRL+ALT+TAB, CTRL+ALT+SHIFT+TAB (tiling.lua);
  - every XF86 key and its SHIFT/ALT variants (media.lua, utilities.lua:9,14);
  - PRINT, ALT+PRINT (utilities.lua:37-38);
  - F9 press and release (voxtype.lua:3-4);
  - the temporary region-capture binds (utilities.lua:56-65).

  These are consistent with ADR-0004's reserved list (Alt+Tab, Ctrl+Alt+Del, Super+Space, Super+Shift+Space).

The table covers the Omarchy defaults only. The user's `~/.config/hypr/bindings.lua` currently adds none. `docs/linux/hyprland.md` gives the rule for the user's own binds: bypass anything tkzmux does not claim.

### Open fields (filled by WOR-301 S6)

| Field | Expected from source | Measured |
|---|---|---|
| `gdk_toplevel_get_capabilities` bits on Hyprland 0.56.2 | MAXIMIZE \| FULLSCREEN, plus INHIBIT_SHORTCUTS; no WINDOW_MENU or MINIMIZE | — |
| Effective `gtk-decoration-layout` under Hyprland | `appmenu:close` (gsettings). If GTK falls back to its compiled-in `menu:minimize,maximize,close`, the intersection gives maximize and close | — |
| `titlebar_gesture` return value on Hyprland | FALSE (no gtk-shell) | — |
| Inhibitor covers `SUPER+mouse:272/273` | Yes (KeybindManager.cpp) | — |
| SUPER+C/V with the inhibitor granted, with and without the `terminal` tag | Neither fires; tkzmux receives ⌘C/⌘V | — |
| Inhibitor granted on focus | Yes (Hyprland implements keyboard-shortcuts-inhibit v1) | — |
| `dont_inhibit` accepted on mouse binds (`mouse = true`) and on the temporary region-capture binds | Unknown from the stub alone | — (WOR-324 S2 if WOR-301 S6 does not reach it) |

If capabilities differ from the expectation, nothing in this ADR changes: the model intersects whatever is reported. If the inhibitor is not granted, the bypass verdicts become moot and the `terminal` tag carries SUPER+C/V on its own. If Super+LMB still drags the window under the inhibitor, the SUPER+mouse:272 row becomes "WM keeps it" and Ctrl+click becomes the primary link chord (ADR-0004).

## Consequences

- **Positive.**
  - The window follows each desktop's own button convention, and on Hyprland it looks like every other tiled app: no buttons except close. Nothing Mac-specific leaks into Linux chrome.
  - The header keeps the Mac's layout and tokens, and only one zone per side differs. Parity stays measurable: L0 excludes the zone and anchors trailing items to it.
  - The capability intersection needs no per-compositor code paths. The `dlsym` gate keeps the GTK 4.16 floor.
  - SUPER+C/V copy and paste in every mode, and never send SIGINT. On-screen pixels are unaltered once the snippet is loaded, which keeps the local grim checks of ADR-0003 valid.
  - Every Omarchy bind keeps working over tkzmux, except the 22 claimed binds in the table (18 rows) and SUPER+1–9 (31 binds in all). Each claimed bind has a tkzmux meaning listed above.
- **Negative.**
  - tkzmux owns all window-chrome behaviour: hit-testing, cursors, gesture fallbacks, live layout updates. GTK would have done this for free with a GtkHeaderBar, but that would break decision 1.
  - With no CSD shadow, the window looks flat on GNOME and KDE, and the resize band sits inside the window.
  - The snippet is mandatory for a correct Omarchy experience, and it must be kept in step with Omarchy's bind files. A new Omarchy bind is silenced over tkzmux until it is bypassed. WOR-324's audit regenerates the table from `/usr/share/omarchy/default/hypr/bindings/*.lua`.
  - The `terminal` tag makes tkzmux depend on Omarchy's clipboard semantics and theme opacity rules. The latter are countered by a rule that must stay last.
  - In fallback mode SUPER+X sends Ctrl+X to the terminal.
  - Claiming SUPER+W/T/F/O, the four SUPER+ALT+arrows and SUPER+1–9 removes those tiling actions over tkzmux; the user reaches them by focusing another window, or restores workspace switching with the documented SUPER+1–9 bypass.

## Alternatives considered

- **Draw macOS traffic lights at the Mac positions.** This is design B's original parity choice (research `designs[1].pixel_parity_strategy`). The user rejected it (decision 7): it looks foreign on Linux, and minimize does not exist on Hyprland.
- **Reserve an empty traffic-light inset and draw no controls.** It is pixel-closer to the Mac, but there would be no close affordance on GNOME, where the compositor draws nothing. Rejected.
- **A GtkHeaderBar or GtkWindowControls, or GTK CSD.** It breaks "GTK never draws a visible pixel" (decision 1) and adds a GSK composite over the offloaded canvas. Rejected.
- **libdecor.** It is on the deny-list (ADR-0001), and its GTK plugin pulls in GTK3 (research `ui-architecture-options` finding 21). Rejected.
- **Server-side decorations where offered (KWin).** This would mean two looks per desktop and a title bar above the header strip. Rejected in favour of one client-drawn header everywhere.
- **Leave the window without the `terminal` tag.** SUPER+C would send SIGINT in fallback mode. Rejected.
- **An app-id that matches Omarchy's terminal regex** (for example `org.omarchy.*`). It would impersonate Omarchy's own windows, and it conflicts with the app-id `se.tkz.tkzmux` (ADR-0002). Rejected.
- **Set `binds:disable_keybind_grabbing`.** It turns off every app's inhibitor globally, which disables Super-as-⌘ (decision 5). Rejected.
- **Claim every colliding chord and bypass nothing.** Inhibition then silences all WM binds, including SUPER+0, media keys and the lock bind. Rejected.
- **Bypass SUPER+1–0 by default.** Rejected in WOR-299 S6; kept as the documented opt-out (section 4).

## Open items

Each item has an owner issue; [decisions.md](decisions.md) carries the same list.

| Item | Owner |
|---|---|
| The open fields above (capability bits, effective decoration layout, `titlebar_gesture` result, mouse-bind inhibition, SUPER+C/V with and without the tag, inhibit grant, `dont_inhibit` on mouse and temporary binds); then `Accepted (final)` or the recorded fallback | WOR-301 S6 (WOR-324 S2 for the last field if WOR-301 S6 does not reach it) |
| The `terminal` tag, revisited with measured inputs | WOR-301 S6 |
| GNOME (Mutter) and KDE (KWin) cells marked *inferred* in section 3 | WOR-314 S6 (non-gating smoke) |
| Settings floats by matching the title `^Settings$`; the main window's title must never be `Settings` | WOR-319 S6 (float-rule check) |
| SUPER+SHIFT+comma becomes a claim in the same PR that gives `reloadConfig` a handler; until then the WOR-324 S5 audit keeps it bypassed | WOR-324 S5 |
| The SUPER+1–9 opt-out lines and the load-order note in `docs/linux/hyprland.md` | WOR-314 S3, WOR-324 S2 |

## References

- **User decisions** 1, 5 and 7 (2026-10-02) and the WOR-299 S6 verdicts, all in [decisions.md](decisions.md).
- **Repo:**
  - `Sources/TkzApp/ChromeViewController.swift:1-11,45-59,114-119`;
  - `Sources/TkzApp/MainWindowController.swift:328-329,532,726-744`;
  - `Sources/TkzApp/Toolbar/MainToolbarController.swift:164,321`;
  - `Sources/TkzApp/Settings/SettingsWindowController.swift:219-230`, `Sources/TkzApp/Settings/SettingsView.swift:17-18,153-154`;
  - `Sources/TkzApp/AppDelegate.swift:171-173`;
  - `Sources/TkzApp/MainMenu.swift:194-201,298`;
  - `Sources/TkzApp/Menus/ShortcutsTable.swift:194-229`;
  - `Sources/TkzTerminalView/MouseController.swift:392-399`;
  - `Sources/TkzCore/Theme.swift:37`;
  - `docs/shortcuts.md:27,29,83`.
- **GTK 4.22.4** `/usr/include/gtk-4.0/gdk/gdktoplevel.h:188,209,218,225-226,305-318`.
  - https://docs.gtk.org/gtk4/property.Settings.gtk-decoration-layout.html
  - https://docs.gtk.org/gtk4/property.Settings.gtk-titlebar-double-click.html
  - https://docs.gtk.org/gtk4/property.Settings.gtk-titlebar-right-click.html
- **xdg-shell** `wm_capabilities`: https://wayland.app/protocols/xdg-shell
- **Hyprland v0.56.2:**
  - https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/CMakeLists.txt (protocol list, from research);
  - https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/src/protocols/XDGShell.cpp (`wm_capabilities` = fullscreen, maximize);
  - https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/src/managers/KeybindManager.cpp (`dontInhibit`, `binds:disable_keybind_grabbing`, mouse binds through `handleKeybinds`).
- **Omarchy (omarchy-settings 4.0.4-1):**
  - `/usr/share/omarchy/default/hypr/windows.lua:3,6,21-25`;
  - `apps/terminals.lua:5-8`, `apps/system.lua:2-3` (float/center rule form);
  - `bindings/{tiling,applications,clipboard,utilities,media,voxtype}.lua`;
  - `omarchy.lua:19-22`;
  - `/usr/share/omarchy/themes/kanagawa/hyprland.lua:18`;
  - `~/.config/hypr/hyprland.lua:14-23`.
- **Research** (`research.json`):
  - `ui-architecture-options` findings 6 and 21, open decision 7;
  - `ui-visual-inventory` open decision 2;
  - `input-keyboard-shortcuts` finding 4, verdict correction 5, missed item 4;
  - `gpu-rendering-backend` verdict correction 2;
  - judges' grafts 7/8/8 and decisive questions;
  - https://linuxiac.com/gnome-50-ends-the-x11-era-after-decades/ (GNOME is Wayland only).
- **Issues:** WOR-301 S6; WOR-314 S3 and S6; WOR-315 S3; WOR-319 S6; WOR-322; WOR-324 S2.
