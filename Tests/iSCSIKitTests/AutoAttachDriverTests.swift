import Foundation
import Testing
@testable import iSCSIKit

/// The attach-at-login run as the app drives it, against a mock host and a
/// clock that moves only when the test moves it. Each case is something the
/// 26.6 VM showed on 2026-10-22; `AutoAttachRun`'s own arithmetic is tested
/// in `AutoAttachRunTests`, not again here.
@Suite("Auto-attach driver", .timeLimit(.minutes(1)))
@MainActor
struct AutoAttachDriverTests {

    private static let iqn = "iqn.2026-08.me.herko:disk0"

    private func record(_ id: String) -> TargetRecord {
        TargetRecord(id: id, displayName: id, host: "192.168.20.1", targetIQN: Self.iqn,
                     lun: 0, autoAttach: true)
    }

    /// The FSKit mount another account's attach leaves in the mount table.
    private let otherAccountsMount = MountTableEntry(
        from: "iscsi://192.168.20.1:3260/\(iqn)/0",
        on: "/Users/a/Library/Caches/me.herko.iSCSIInitiator/e7cf144d2c2ee621")

    private func start(_ host: MockHost, _ clock: ManualClock) -> AutoAttachDriver<MockHost, ManualClock> {
        let driver = AutoAttachDriver(host: host, clock: clock)
        host.driver = driver
        driver.start { host.finished() }
        return driver
    }

    // MARK: App Nap

    @Test("the run keeps App Nap off from its start until it ends")
    func activitySpansTheRun() async {
        // A windowless app is napped within seconds of an attempt that makes no
        // XPC call; its 15 s sleeps stretched to 70–100 s on the VM.
        let host = MockHost(targets: [record("t")])
        let clock = ManualClock()
        let driver = start(host, clock)
        #expect(host.activitiesBegun == 1)
        #expect(host.activitiesEnded == 0)

        await host.waitUntil { host.finishes == 1 }
        #expect(host.activitiesEnded == 1)
        #expect(!driver.isRunning)
        clock.cancelSleepers()
    }

    @Test("uninstalling mid-run ends the activity once, and a late result does not end it again")
    func uninstallEndsTheActivityOnce() async {
        let host = MockHost(targets: [record("t")])
        host.holdNextAttach = ["t"]
        let clock = ManualClock()
        let driver = start(host, clock)
        await host.waitUntil { host.isHeld("t") }

        driver.cancelAll()
        #expect(host.activitiesEnded == 1)

        host.release("t", with: nil)
        await host.waitUntil { host.clears == ["t"] }
        #expect(host.activitiesEnded == 1)
        #expect(host.windowsShown == 0)
        #expect(host.finishes == 0)
        clock.cancelSleepers()
    }

    // MARK: The window at the end of the run

    @Test("a run that ends with a target unattached opens the window and records its last error")
    func failureAtTheEndOpensTheWindow() async {
        // With the menu bar item hidden, only the host's own request (the URL)
        // brought the window up; the run must ask for it exactly once.
        let host = MockHost(targets: [record("t")])
        host.outcomes = ["t": [.attach("did not answer in time")]]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.attachCalls.count == 1 }

        clock.advance(by: .seconds(300))
        await host.waitUntil { host.finishes == 1 }
        #expect(host.windowsShown == 1)
        #expect(host.recorded == ["t": .attach("did not answer in time")])
        #expect(host.activitiesEnded == 1)
        clock.cancelSleepers()
    }

    @Test("a run that attached everything does not open the window")
    func successDoesNotOpenTheWindow() async {
        let host = MockHost(targets: [record("t")])
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.finishes == 1 }
        #expect(host.windowsShown == 0)
        #expect(host.recorded.isEmpty)
        #expect(host.attachCalls == ["t"])
        clock.cancelSleepers()
    }

    @Test("a run that never could read the target list opens the window at five minutes")
    func unreadListOpensTheWindow() async {
        // Setup blocked by another registered copy of the app: no target list,
        // nothing to attach, and the window is how the user finds out.
        let host = MockHost(targets: [record("t")])
        host.readAnswers = [false]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.reads == 1 }

        clock.advance(by: .seconds(300))
        await host.waitUntil { host.finishes == 1 }
        #expect(host.windowsShown == 1)
        #expect(host.attachCalls.isEmpty)
        #expect(host.recorded.isEmpty)
        clock.cancelSleepers()
    }

    // MARK: An attempt that outlives the run

    @Test("a deadline in the middle of an attempt reports the target as still attaching")
    func deadlineMidAttemptIsStillAttaching() async {
        let host = MockHost(targets: [record("t")])
        host.holdNextAttach = ["t"]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.isHeld("t") }

        clock.advance(by: .seconds(300))
        await host.waitUntil { host.finishes == 1 }
        #expect(host.recorded == ["t": .kind(.stillAttaching)])
        #expect(host.windowsShown == 1)

        host.release("t", with: .attach("released"))
        await host.waitUntil { host.recorded["t"] == .attach("released") }
        clock.cancelSleepers()
    }

    @Test("an attempt that attaches after the run has ended clears its warning")
    func lateSuccessClearsTheWarning() async {
        // The VM's second two-account run: the deadline passed while the attach
        // was under way, and the volume arrived afterwards.
        let host = MockHost(targets: [record("t")])
        host.holdNextAttach = ["t"]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.isHeld("t") }
        clock.advance(by: .seconds(300))
        await host.waitUntil { host.finishes == 1 }

        host.release("t", with: nil)
        await host.waitUntil { host.clears == ["t"] }
        #expect(host.recorded.isEmpty)
        #expect(host.windowsShown == 1)
        clock.cancelSleepers()
    }

    @Test("an attempt held up past its next start time is followed at once")
    func overdueAttemptIsFollowedAtOnce() async {
        // App Nap froze an attempt for minutes; when it finished, the next one
        // started immediately instead of waiting another 15 s.
        let host = MockHost(targets: [record("t")])
        host.holdNextAttach = ["t"]
        host.outcomes = ["t": [.attach("still unreachable")]]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.isHeld("t") }

        clock.advance(by: .seconds(40))
        host.release("t", with: .attach("unreachable"))
        await host.waitUntil { host.attachCalls.count == 2 }
        clock.cancelSleepers()
    }

    // MARK: Two accounts

    @Test("another account's mount blocks every attempt, and the attempt after it is ejected attaches")
    func ejectInTheOtherAccountLetsTheNextAttemptAttach() async {
        let host = MockHost(targets: [record("t")])
        host.mounts = [otherAccountsMount]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.failuresMade == [.inUseElsewhere] }
        #expect(host.attachCalls.isEmpty)

        clock.advance(by: .seconds(15))
        await host.waitUntil { host.failuresMade == [.inUseElsewhere, .inUseElsewhere] }
        #expect(host.attachCalls.isEmpty)

        host.mounts = []
        clock.advance(by: .seconds(15))
        await host.waitUntil { host.finishes == 1 }
        #expect(host.attachCalls == ["t"])
        #expect(host.windowsShown == 0)
        #expect(host.recorded.isEmpty)
        clock.cancelSleepers()
    }

    @Test("a target still in use at five minutes is reported as in use elsewhere")
    func stillInUseAtTheEndIsReported() async {
        let host = MockHost(targets: [record("t")])
        host.mounts = [otherAccountsMount]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.failuresMade == [.inUseElsewhere] }

        clock.advance(by: .seconds(300))
        await host.waitUntil { host.finishes == 1 }
        #expect(host.recorded == ["t": .kind(.inUseElsewhere)])
        #expect(host.windowsShown == 1)
        #expect(host.attachCalls.isEmpty)
        clock.cancelSleepers()
    }

    // MARK: Schedule on the run's clock

    @Test("attempts start 15 s apart on the run's own clock")
    func attemptsAreFifteenSecondsApart() async {
        let host = MockHost(targets: [record("t")])
        host.outcomes = ["t": [.attach("unreachable")]]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.attachCalls.count == 1 }

        clock.advance(by: .seconds(14))
        #expect(host.attachCalls.count == 1)
        clock.advance(by: .seconds(1))
        await host.waitUntil { host.attachCalls.count == 2 }
        clock.cancelSleepers()
    }

    // MARK: The user got there first

    @Test("a target the user acted on while the list was being read is never attempted")
    func takenOverDuringTheReadIsNotAttempted() async {
        let host = MockHost(targets: [record("t")])
        host.holdNextRead = true
        let clock = ManualClock()
        let driver = start(host, clock)
        await host.waitUntil { host.isReadHeld }

        driver.cancel(targetID: "t")
        host.releaseRead(true)
        await host.waitUntil { host.finishes == 1 }
        #expect(host.attachCalls.isEmpty)
        #expect(host.windowsShown == 0)
        clock.cancelSleepers()
    }

    @Test("a target the user is attaching by hand is left to them")
    func busyTargetIsLeftToTheUser() async {
        let host = MockHost(targets: [record("t")])
        host.busy = ["t"]
        let clock = ManualClock()
        _ = start(host, clock)
        await host.waitUntil { host.finishes == 1 }
        #expect(host.attachCalls.isEmpty)
        #expect(host.windowsShown == 0)
        #expect(host.recorded.isEmpty)
        clock.cancelSleepers()
    }
}
