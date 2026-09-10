// ScrollMetricsReportTests — `TerminalMetalView.onScrollMetricsChanged` is the diffed form of the
// per-frame scroll poll: it fires when the position changed and stays silent otherwise, and a
// session swap forgets the last report so the incoming session's first frame is reported.

import AppKit
import Metal
import Testing
import TkzTerminalCore
import TkzTerminalRender

@testable import TkzTerminalView

@Suite("Scroll metrics report", .serialized)
@MainActor
struct ScrollMetricsReportTests {

    @Test("fires on change only, and again after a session swap")
    func reportsChangesOnly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let context = try TerminalRenderContext(scale: 2)
        let view = TerminalMetalView(renderContext: context, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var reports: [TerminalScrollMetrics] = []
        view.onScrollMetricsChanged = { reports.append($0) }

        let scrolled = TerminalScrollMetrics(total: 240, offset: 190, visible: 40, isAlternateScreen: false)
        view.reportScrollMetrics(.empty)
        view.reportScrollMetrics(.empty)
        view.reportScrollMetrics(scrolled)
        view.reportScrollMetrics(scrolled)
        #expect(reports == [.empty, scrolled])

        // Showing a session (even none) clears the diff key: the next frame is always reported.
        view.show(nil)
        view.reportScrollMetrics(scrolled)
        #expect(reports.count == 3)
    }

    @Test("the wheel callback carries the rows the accumulator produced, negative = up")
    func wheelCallback() throws {
        let mouse = MouseController()
        var rows: [Int] = []
        mouse.onWheelRows = { rows.append($0) }
        // The callback is fired by `scrollWheel`, which needs a real terminal; the contract the
        // policy relies on — sign and units — is `wheelRows`'s, asserted here directly.
        let up = mouse.wheelRows(deltaY: 3, hasPreciseDeltas: false, backingScale: 2, cellHeightPx: 30, gestureEnded: true)
        #expect(up == -3, "scrollingDeltaY > 0 is the viewport moving up, reported as negative rows")
        #expect(rows.isEmpty, "wheelRows alone does not fire; scrollWheel does")
    }
}
