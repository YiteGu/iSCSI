import Foundation
import Testing
@testable import iSCSIVolume

/// When the extension gives up on a resource FSKit loaded and never activated.
/// Every time is an instant built from one origin, so nothing waits.
@Suite("Activation watch")
struct ActivationWatchTests {
    private let t0 = ContinuousClock.now

    @Test("a load is not given up before the grace period ends")
    func notGivenUpWithinGrace() {
        var watch = ActivationWatch()
        watch.loaded(at: t0)
        #expect(!watch.shouldGiveUp(at: t0 + .seconds(29)))
    }

    @Test("a load with no activate is given up after 30 s")
    func givenUpAfterGrace() {
        var watch = ActivationWatch()
        watch.loaded(at: t0)
        #expect(watch.shouldGiveUp(at: t0 + .seconds(30)))
    }

    @Test("an activate keeps the instance for good")
    func activateKeepsTheInstance() {
        var watch = ActivationWatch()
        watch.loaded(at: t0)
        watch.activated()
        #expect(!watch.shouldGiveUp(at: t0 + .seconds(60)))
    }

    @Test("an instance that has served a volume is never given up, even after another load")
    func servedInstanceIsNeverGivenUp() {
        var watch = ActivationWatch()
        watch.loaded(at: t0)
        watch.activated()
        watch.loaded(at: t0 + .seconds(40))
        #expect(!watch.shouldGiveUp(at: t0 + .seconds(100)))
    }

    @Test("an instance that never loaded anything is not given up")
    func nothingLoadedIsNotGivenUp() {
        let watch = ActivationWatch()
        #expect(!watch.shouldGiveUp(at: t0 + .seconds(100)))
    }

    @Test("a second load does not restart the grace period")
    func secondLoadKeepsTheFirstDeadline() {
        var watch = ActivationWatch()
        watch.loaded(at: t0)
        watch.loaded(at: t0 + .seconds(20))
        #expect(watch.shouldGiveUp(at: t0 + .seconds(30)))
    }
}
