// SidebarRowModels — the *presentation* input to the sidebar row views (M2.3 / TKZ-19).
//
// These structs deliberately contain **no `TkzCore` model types** (`Session`, `Group`,
// `SessionStatus`, `Account`, …). The row views are built and tested against them alone, so the
// presentation layer can land before the store (TKZ-17) exists, and so a row can be rendered
// headlessly from a literal in a test without standing up an `AppStore`.
//
// Wave 2 (`SidebarViewController`, M2.4) writes the one adapter that maps the real models onto
// these — that adapter is the only place allowed to know both vocabularies. Every field below is
// documented with what the real model is expected to supply.
//
// All types are `Sendable` value types: a row model can be built off the main actor and handed to
// the view. Rendering is deterministic — the same model produces byte-identical output, which the
// tests assert, so nothing here may depend on `Hasher` (per-process seeded), the clock, or the
// environment. `accountChipColor(forKey:)` is the derivation that would be tempting to do with
// `hashValue`; it uses FNV-1a instead.

import TkzCore

/// The lifecycle state a session's dot represents.
///
/// Maps from `TkzCore.SessionStatus` (M2.1) — that type carries a *reason* with `waiting`
/// (`.permission` / `.agentInput` / `.doneUnattended`); the sidebar dot does not distinguish them,
/// so the adapter collapses all three to `.waiting`. Whether the row also shows the `NEEDS YOU`
/// badge is a separate flag (`SidebarSessionRowModel.needsAttention`), because only
/// `waiting(.doneUnattended)` earns it.
public enum SidebarStatus: String, Hashable, Sendable, CaseIterable {
    /// Claude is busy. This is the only status that pulses.
    case working
    /// Claude is blocked on the human (permission prompt, elicitation, or done-unattended).
    case waiting
    /// Alive but nothing is happening — and the catch-all for no Claude at all, a restored row with
    /// no terminal, a parked job, an attended Stop. **Draws no dot** (2026-09-09).
    case idle
    /// Claude finished less than a minute ago and nobody has looked yet: idle with the accent
    /// tint, so a finished answer is visible before it ages into `NEEDS YOU` (GUI pass
    /// 2026-09-08, 5c: the dot went straight from green to grey).
    case done
}

/// One 44 pt session row.
public struct SidebarSessionRowModel: Hashable, Sendable {
    /// Resolved display title (user rename → descriptor name → worktree name → `basename(cwd)`).
    /// Long titles truncate with an ellipsis; the sidebar is 240–300 pt wide, so this is normal.
    public var title: String

    /// Current git branch, *without* any decoration — the view renders it as `⎇ <branch>`.
    /// `nil` when the cwd is not a repo (or git status has not landed yet); the detail line then
    /// shows only the badges.
    public var branch: String?

    /// The folder the session lives in, shown as `…/<directory>` in front of the branch — but only
    /// when the title is *not* already that folder (design 2c.1: "Blazor grid fix" gets
    /// `…/FIIPEV · ⎇ develop`, "FIM" shows only `⎇ develop`). `nil` hides it. The adapter passes
    /// `Session.directoryTitle` when it differs from `displayTitle`, so a Claude-named or renamed
    /// row keeps its folder in view. When `…/dir · ⎇ branch [WT]` does not fit the row, the branch
    /// moves to a second detail line and the row grows to `SidebarMetrics.sessionRowWrappedHeight`.
    public var directory: String?

    /// `true` when the session's cwd is a git worktree (`GitStatus.RepoInfo.isWorktree`).
    /// Drives the `WT` badge on the detail line.
    public var isWorktree: Bool

    /// Colour and pulse of the status dot. See `SidebarStatus`.
    public var status: SidebarStatus

    /// Short label for the Claude account this session runs under (e.g. the account key's initials
    /// or its configured short name). `nil` hides the account chip entirely — which is what a
    /// single-account setup should pass, so the row does not carry a meaningless chip.
    public var accountLabel: String?

    /// What hovering the chip says: the account's full name and its config dir. `nil` alongside a
    /// non-nil ``accountLabel`` simply means no tooltip — five characters is not much to go on, so
    /// the adapter always supplies one in practice.
    public var accountTooltip: String?

    /// Chip tint. Passed in rather than derived inside the view so the mapping stays testable and
    /// so a user-configured account colour can override the default. When the adapter has no
    /// configured colour it should call `SidebarSessionRowModel.accountChipColor(forKey:)`.
    /// `nil` with a non-nil `accountLabel` falls back to the theme's muted foreground.
    public var accountColor: RGB?

    /// `true` when the session is *waiting on the human and has been for a while* — i.e.
    /// `waiting(.doneUnattended)`, and by extension a pending permission prompt the user has not
    /// seen. Drives the amber `NEEDS YOU` badge, and nothing else.
    public var needsAttention: Bool

    /// `true` for the outline view's selected row. The view paints its own selection background
    /// (`Theme.selection`) rather than relying on `NSOutlineView`'s, because the design's selection
    /// is an inset rounded rect, not a full-bleed system highlight.
    public var isSelected: Bool

    /// A short size string ("6.2 GB") when this session's *processes* are holding an alarming
    /// amount of memory, else `nil` — which hides the badge entirely.
    ///
    /// Deliberately absent for a normal session, following the same rule as the account chip: a
    /// badge every row carries is a badge nobody reads. `SidebarRowAdapter` decides the threshold.
    public var memoryBadge: String?

    /// The **containing group's** colour, so the 2.5 pt edge runs down the whole group rather than
    /// stopping at its header (TKZ-48). `nil` — an uncoloured group — leaves the edge layer fully
    /// transparent, exactly as on the header; it is never `Theme.groupEdgeDefault`.
    public var groupColor: RGB?

    public init(
        title: String,
        branch: String? = nil,
        directory: String? = nil,
        isWorktree: Bool = false,
        status: SidebarStatus = .idle,
        accountLabel: String? = nil,
        accountTooltip: String? = nil,
        accountColor: RGB? = nil,
        needsAttention: Bool = false,
        isSelected: Bool = false,
        groupColor: RGB? = nil,
        memoryBadge: String? = nil
    ) {
        self.title = title
        self.branch = branch
        self.directory = directory
        self.isWorktree = isWorktree
        self.status = status
        self.accountLabel = accountLabel
        self.accountTooltip = accountTooltip
        self.accountColor = accountColor
        self.needsAttention = needsAttention
        self.isSelected = isSelected
        self.groupColor = groupColor
        self.memoryBadge = memoryBadge
    }
}

extension SidebarSessionRowModel {
    /// A stable, process-independent colour for an account key.
    ///
    /// `Hashable.hashValue` is seeded per process and would give the same account a different chip
    /// colour on every launch, so this uses FNV-1a over the UTF-8 bytes and picks one of a small
    /// fixed set of hues. The palette is intentionally tiny and mid-saturation: it must read on all
    /// five presets, and with two accounts (the v1 scope) any two distinct keys should look
    /// distinct.
    public static func accountChipColor(forKey key: String) -> RGB {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        let palette: [RGB] = [
            RGB(hex: 0x8b93f8),  // indigo
            RGB(hex: 0x41c6a8),  // teal
            RGB(hex: 0xe0956a),  // Claude orange
            RGB(hex: 0xc084fc),  // magenta
            RGB(hex: 0x5b8def),  // blue
            RGB(hex: 0xf28b8b),  // red
        ]
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// One 28 pt group header row.
public struct SidebarGroupRowModel: Hashable, Sendable {
    /// Group name as the user typed it. The view uppercases it for display; do **not** pre-uppercase
    /// here — the palette and the toolbar subtitle want the original casing.
    public var name: String

    /// The group's colour edge. `nil` means *this group has no colour*, and the 2.5 pt edge layer is
    /// left fully transparent (it stays in the tree so layout never shifts). `Theme.groupEdgeDefault`
    /// is **not** substituted here: it is the colour the *picker* offers as a default, not a
    /// fallback for an uncoloured group.
    ///
    /// The same colour reaches every session row in the group as
    /// `SidebarSessionRowModel.groupColor`, so the edge is one continuous stripe.
    public var color: RGB?

    /// Disclosure state, from `NSOutlineView.isItemExpanded`. Drives the chevron glyph only; the
    /// outline view owns the actual expansion.
    public var isCollapsed: Bool

    public init(name: String, color: RGB? = nil, isCollapsed: Bool = false) {
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }
}

/// The "N working · N need you" strip under the session list.
public struct SidebarSummaryModel: Hashable, Sendable {
    /// Sessions whose status is `.working`.
    public var working: Int
    /// Sessions with `needsAttention` — i.e. the ones showing a `NEEDS YOU` badge. This is a count
    /// of *badges*, not of `.waiting` dots; the two differ when a permission prompt is fresh.
    public var needAttention: Int

    public init(working: Int = 0, needAttention: Int = 0) {
        self.working = working
        self.needAttention = needAttention
    }
}

// MARK: - Update card (TKZ-50)

/// What a click on the update card's second line asks the owner to do.
public enum UpdateAction: Hashable, Sendable {
    /// Run `brew update` + `brew upgrade --cask`.
    case upgrade
    /// The bundle on disk is new: quit and reopen.
    case restart
    /// Run brew again (after a failure, or when the cask was not bumped yet).
    case retry
    /// Reveal `~/Library/Logs/tkzmux/update.log`.
    case showLog
    /// Open the GitHub release page.
    case openReleasePage
}

/// The 48 pt "Update available" card. `nil` from the adapter means no card at all.
public struct UpdateNoticeModel: Hashable, Sendable {
    /// One run on the second line; a run with an `action` is drawn as a link.
    public struct Run: Hashable, Sendable {
        public var text: String
        public var action: UpdateAction?

        public init(_ text: String, action: UpdateAction? = nil) {
            self.text = text
            self.action = action
        }
    }

    /// "Update available — v0.8.0".
    public var title: String
    /// Rendered left to right, separated by " · ".
    public var runs: [Run]
    /// The `✕`; hidden while brew is running.
    public var showsClose: Bool

    public init(title: String, runs: [Run], showsClose: Bool = true) {
        self.title = title
        self.runs = runs
        self.showsClose = showsClose
    }
}

// MARK: - Shared metrics

/// Fixed geometry from the design (artboard 2c). The outline view returns these from
/// `outlineView(_:heightOfRowByItem:)`, so they live next to the models rather than inside a view.
public enum SidebarMetrics {
    /// Group header height, in points.
    public static let groupRowHeight: Double = 28
    /// Session row height, in points — the single-detail-line row. The outline view no longer
    /// returns this blindly: it asks `SessionRowView.height(for:width:)` per row, which is this
    /// unless the row's `…/dir · ⎇ branch` line wraps.
    public static let sessionRowHeight: Double = 44
    /// A session row whose detail line wrapped to two (`…/dir` above `⎇ branch [WT]`): one more
    /// 15 pt detail line. Never taller — two lines is the cap.
    public static let sessionRowWrappedHeight: Double = 59
    /// Summary strip height, in points.
    public static let summaryStripHeight: Double = 26
    /// The "＋ New group" footer strip: a 26 pt dashed button with 2 pt above and 10 pt below.
    public static let newGroupFooterHeight: Double = 38
    /// The "Update available" card above the footer (TKZ-50): a 40 pt card with 2 pt above and
    /// 6 pt below. Only laid out while a card is showing.
    public static let updateNoticeHeight: Double = 48
    /// How far a session row's content sits inside its group header's.
    ///
    /// `NSOutlineView.indentationPerLevel` is 0 because the rows lay themselves out, so the
    /// hierarchy has to come from here. Without it a session title sat at x=30 against a group name
    /// at x=25 — five points, which reads as no hierarchy at all (reported 2026-09-08).
    /// 16 pt matches AppKit's own default indentation per level. Raising it costs title width in a
    /// 300 pt sidebar, where long session titles already truncate, so it is a real trade.
    public static let sessionIndent: Double = 16
    /// Width of the group colour edge (design says 2–3 pt).
    public static let groupEdgeWidth: Double = 2.5
    /// Nominal sidebar width and its minimum — titles must truncate at the minimum.
    public static let sidebarWidth: Double = 300
    public static let sidebarMinWidth: Double = 240
}
