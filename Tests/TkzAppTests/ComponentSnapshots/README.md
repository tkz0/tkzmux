# Component snapshot goldens

The Mac app's components rendered headlessly, one PNG and one layout dump per component, theme
preset and scale (WOR-307). They pin the Mac's look while the M3 refactors move its code, and they
are what the Linux canvas views are measured against (ADR-0003, layers L0 and L5).

- `<component>@<preset>@<scale>.png` is an sRGB render: RGB when it is opaque, else RGBA.
- `<component>@<preset>@<scale>.json` is its `LayoutDump` (frames in logical points, top-left
  origin; text runs, masks, frozen animations), as canonical compact JSON. `jq -S .` reads one.
- `manifest.json` names the reference machine, lists every file's size and sha256, sums them
  against WOR-307's 4.5 MiB share of ADR-0003's budget, and lists the edges off the 0.5 pt grid.

Never edit or regenerate these by hand, and never in a commit that also changes the app: a
changed golden in a refactor means the refactor changed what the Mac draws. Regenerate on the
reference runner only, with the `Component snapshots` workflow, or there with:

```sh
find Tests/TkzAppTests/ComponentSnapshots -type f ! -name README.md -delete
TKZMUX_UPDATE_SNAPSHOTS=1 swift test --no-parallel --filter ComponentSnapshot
swift test --no-parallel --filter ComponentSnapshot
```

The same run measures the typography roles and writes `Sources/TkzCore/DesignTokens+LineMetrics.swift`
(the workflow's `typography-line-metrics` artifact); commit it with the set.

Until a set is committed the golden suite is skipped. The schema, the snapping kinds and the
whole update flow are in [docs/linux/parity.md](../../../docs/linux/parity.md).
