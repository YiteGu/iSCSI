import Testing
@testable import iSCSIKit

/// The disk image layer of an attach, given what `hdiutil` already has bound to
/// the LUN's image path.
@Suite("Image attach plan")
struct ImageAttachPlanTests {

    @Test("with nothing attached, attach")
    func noDeviceAttachesFresh() {
        #expect(ImageAttachPlan.decide(fskitWasMounted: false, existingDevice: nil) == .attach)
        #expect(ImageAttachPlan.decide(fskitWasMounted: true, existingDevice: nil) == .attach)
    }

    @Test("a device over the FSKit mount that was already up is reused")
    func deviceOverLiveMountIsReused() {
        #expect(ImageAttachPlan.decide(fskitWasMounted: true, existingDevice: "/dev/disk9")
                == .reuse(device: "/dev/disk9"))
    }

    /// Measured 2026-10-22: logging out with a volume attached takes the FSKit
    /// mount down but can leave the disk image device behind, bound to the same
    /// path and serving nothing. Reusing it attached a dead disk and called it
    /// success.
    @Test("a device left from before this FSKit mount existed is stale")
    func deviceOverAFreshMountIsStale() {
        #expect(ImageAttachPlan.decide(fskitWasMounted: false, existingDevice: "/dev/disk9")
                == .replaceStale(device: "/dev/disk9"))
    }
}
