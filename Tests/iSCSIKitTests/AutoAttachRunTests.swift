import Foundation
import Testing
@testable import iSCSIKit

/// The login-time retry schedule, decided without a clock: every time here is
/// an offset from the start of the run, so nothing waits.
@Suite("Auto-attach run")
struct AutoAttachRunTests {

    private func record(_ id: String, autoAttach: Bool = true, lun: UInt64 = 0) -> TargetRecord {
        TargetRecord(id: id, displayName: id, host: "192.168.20.1",
                     targetIQN: "iqn.2026-08.me.herko:disk0", lun: lun, autoAttach: autoAttach)
    }

    private func session(lun: UInt64 = 0) -> SessionInfo {
        SessionInfo(handle: "h", targetIQN: "iqn.2026-08.me.herko:disk0", lun: lun,
                    writeThrough: true, recoveryCount: 0, negotiated: [:])
    }

    @Test("every pending target may start at once")
    func everyTargetStartsAtOnce() {
        let run = AutoAttachRun(targetIDs: ["a", "b"])
        #expect(run.canStart("a", at: .zero))
        #expect(run.canStart("b", at: .zero))
    }

    @Test("attempts start 15 s apart, start to start")
    func attemptsAreFifteenSecondsApart() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        run.finished("a", attached: false)
        #expect(run.nextStart(for: "a") == .seconds(15))
        #expect(!run.canStart("a", at: .seconds(14)))
        #expect(run.canStart("a", at: .seconds(15)))
    }

    @Test("an attempt that overruns delays the next one instead of overlapping it")
    func overrunDelaysInsteadOfOverlapping() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        #expect(!run.canStart("a", at: .seconds(20)))
        run.finished("a", attached: false)
        #expect(run.canStart("a", at: .seconds(20)))
    }

    @Test("no attempt starts at or after five minutes")
    func noAttemptStartsAtTheBudget() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .seconds(285))
        run.finished("a", attached: false)
        #expect(run.nextStart(for: "a") == nil)
        #expect(!run.canStart("a", at: .seconds(300)))
    }

    @Test("the deadline holds while an attempt is still in flight")
    func deadlineHoldsWithAttemptInFlight() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .seconds(290))
        #expect(!run.isOver(at: .seconds(299)))
        #expect(run.isOver(at: .seconds(300)))
        #expect(run.failures == ["a": .stillAttaching])
    }

    @Test("a target that kept failing is reported with its last attempt")
    func failedTargetReportsLastAttempt() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        run.finished("a", attached: false)
        #expect(run.isOver(at: .seconds(300)))
        #expect(run.failures == ["a": .lastAttemptFailed])
    }

    @Test("an attached target is not retried and is not a failure")
    func attachedTargetIsDone() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        run.finished("a", attached: true)
        #expect(run.nextStart(for: "a") == nil)
        #expect(run.isOver(at: .seconds(1)))
        #expect(run.failures.isEmpty)
    }

    @Test("the run ends early only once every target is resolved")
    func runEndsEarlyOnlyWhenAllResolved() {
        var run = AutoAttachRun(targetIDs: ["a", "b"])
        run.started("a", at: .zero)
        run.finished("a", attached: true)
        run.started("b", at: .zero)
        run.finished("b", attached: false)
        #expect(!run.isOver(at: .seconds(20)))
        run.cancel("b")
        #expect(run.isOver(at: .seconds(20)))
        #expect(run.failures.isEmpty)
    }

    @Test("a late result for a cancelled target does not bring it back")
    func cancelledTargetStaysCancelled() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        run.cancel("a")
        run.finished("a", attached: false)
        #expect(run.nextStart(for: "a") == nil)
        #expect(!run.canStart("a", at: .seconds(60)))
        #expect(run.failures.isEmpty)
    }

    @Test("a run with nothing to attach is over immediately")
    func emptyRunIsOverImmediately() {
        #expect(AutoAttachRun(targetIDs: []).isOver(at: .zero))
    }

    @Test("only marked targets that are not attached are pending")
    func onlyMarkedUnattachedTargetsArePending() {
        let targets = [record("t1"), record("t2"), record("t3", autoAttach: false)]
        #expect(AutoAttachRun.pendingTargetIDs(targets, attachedTargetIDs: ["t2"], excluding: []) == ["t1"])
    }

    @Test("another session on the target counts as in use elsewhere")
    func sessionElsewhereCountsAsInUse() {
        #expect(AutoAttachRun.isInUseElsewhere(record("t1"), sessions: [session()],
                                               attachedTargetIDs: [], mountedTags: []))
    }

    @Test("this user's own attachment is not in use elsewhere")
    func ownAttachmentIsNotElsewhere() {
        #expect(!AutoAttachRun.isInUseElsewhere(record("t1"), sessions: [session()],
                                                attachedTargetIDs: ["t1"], mountedTags: []))
    }

    @Test("this user's own mount that never made it into the attachment list is not elsewhere")
    func ownUnrecordedMountIsNotElsewhere() {
        // `mount -F` succeeded, then the image layer failed: the FSKit mount
        // holds a session, but the app never recorded an attachment.
        let target = record("t1")
        let tag = MountpointTag.derive(portal: MountpointTag.portal(host: target.host,
                                                                    port: target.port),
                                       targetIQN: target.targetIQN, lun: target.lun)
        #expect(!AutoAttachRun.isInUseElsewhere(target, sessions: [session()],
                                                attachedTargetIDs: [], mountedTags: [tag]))
    }

    @Test("a target the user took over before the run began is not pending")
    func targetTakenOverBeforeRunIsNotPending() {
        let targets = [record("t1"), record("t2")]
        #expect(AutoAttachRun.pendingTargetIDs(targets, attachedTargetIDs: [],
                                               excluding: ["t1"]) == ["t2"])
    }

    @Test("cancelling every target ends the run with nothing to report")
    func cancellingEverythingEndsTheRun() {
        var run = AutoAttachRun(targetIDs: ["a", "b"])
        run.started("a", at: .zero)
        run.cancelAll()
        #expect(run.isOver(at: .seconds(1)))
        #expect(!run.canStart("b", at: .seconds(1)))
        #expect(run.failures.isEmpty)
    }

    @Test("a session on another LUN of the same target does not count")
    func otherLUNDoesNotCount() {
        #expect(!AutoAttachRun.isInUseElsewhere(record("t1", lun: 0), sessions: [session(lun: 1)],
                                                attachedTargetIDs: [], mountedTags: []))
    }
}
