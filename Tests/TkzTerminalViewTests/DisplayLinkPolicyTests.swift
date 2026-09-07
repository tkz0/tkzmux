// The pause/resume decision, tested without a window, a screen or a run loop.
// `DisplayLinkPolicy` is the same code the app runs; `DisplayLinkDriver` with no adopted link is
// the same bookkeeping the app runs.
import Testing
@testable import TkzTerminalView

@Suite("Display link policy")
struct DisplayLinkPolicyTests {
    private let policy = DisplayLinkPolicy()

    private func demand(_ mutate: (inout DisplayLinkDemand) -> Void) -> DisplayLinkDemand {
        var value = DisplayLinkDemand()
        value.hasVisibleSession = true
        mutate(&value)
        return value
    }

    @Test("an idle attached terminal does not run the link")
    func idleParks() {
        #expect(policy.shouldRun(demand { _ in }) == false)
    }

    @Test("each kind of work runs the link")
    func workRuns() {
        #expect(policy.shouldRun(demand { $0.needsUpdate = true }))
        #expect(policy.shouldRun(demand { $0.isDragging = true }))
        #expect(policy.shouldRun(demand { $0.hasSyncDeadline = true }))
        #expect(policy.shouldRun(demand { $0.isLiveResizing = true }))
    }

    @Test("occlusion vetoes every kind of work")
    func occlusionVetoes() {
        var value = demand {
            $0.needsUpdate = true
            $0.isDragging = true
            $0.hasSyncDeadline = true
            $0.isLiveResizing = true
        }
        value.isOccluded = true
        #expect(policy.shouldRun(value) == false)
    }

    @Test("no attached session means nothing to draw")
    func detachedVetoes() {
        var value = DisplayLinkDemand()
        value.needsUpdate = true
        value.hasVisibleSession = false
        #expect(policy.shouldRun(value) == false)
    }

    @Test("transitions only fire on a real change")
    func transitions() {
        let running = demand { $0.needsUpdate = true }
        let idle = demand { _ in }
        #expect(policy.transition(isPaused: true, demand: running) == .resume)
        #expect(policy.transition(isPaused: false, demand: running) == .unchanged)
        #expect(policy.transition(isPaused: false, demand: idle) == .pause)
        #expect(policy.transition(isPaused: true, demand: idle) == .unchanged)
    }
}

@Suite("Display link driver")
@MainActor
struct DisplayLinkDriverTests {
    @Test("a fresh driver is parked and stays parked without a session")
    func startsParked() {
        let driver = DisplayLinkDriver()
        #expect(driver.isPaused)
        #expect(driver.hasLink == false)
        driver.requestFrame()
        #expect(driver.isPaused, "no attached session: a frame request must not resume the link")
        #expect(driver.resumeCount == 0)
    }

    @Test("work resumes the link and its absence parks it again, each transition logged once")
    func resumeAndPause() {
        let driver = DisplayLinkDriver()
        driver.update { $0.hasVisibleSession = true }
        #expect(driver.isPaused)

        driver.requestFrame()
        #expect(driver.isPaused == false)
        #expect(driver.resumeCount == 1)

        driver.requestFrame()  // already running: no second transition
        #expect(driver.resumeCount == 1)
        #expect(driver.transitions.count == 1)

        driver.update { $0.needsUpdate = false }
        #expect(driver.isPaused)
        #expect(driver.pauseCount == 1)
        #expect(driver.transitions.count == 2)
        #expect(driver.transitions.last?.isPaused == true)
    }

    @Test("occlusion parks a running link and un-occlusion is needed to resume")
    func occlusionParks() {
        let driver = DisplayLinkDriver()
        driver.update {
            $0.hasVisibleSession = true
            $0.needsUpdate = true
        }
        #expect(driver.isPaused == false)

        driver.update { $0.isOccluded = true }
        #expect(driver.isPaused)
        #expect(driver.pauseCount == 1)

        driver.requestFrame()
        #expect(driver.isPaused, "an occluded window must stay parked")

        driver.update { $0.isOccluded = false }
        #expect(driver.isPaused == false)
        #expect(driver.resumeCount == 2)
    }

    @Test("a drag keeps the link alive even when the terminal is idle")
    func dragKeepsAlive() {
        let driver = DisplayLinkDriver()
        driver.update {
            $0.hasVisibleSession = true
            $0.isDragging = true
        }
        #expect(driver.isPaused == false)
        driver.update { $0.needsUpdate = false }
        #expect(driver.isPaused == false)
        driver.update { $0.isDragging = false }
        #expect(driver.isPaused)
    }
}
