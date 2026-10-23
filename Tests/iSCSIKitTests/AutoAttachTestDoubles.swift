import Foundation
@testable import iSCSIKit

/// A clock that moves only when the test moves it, so a five-minute run takes
/// no time at all and nothing depends on how busy the machine is.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var lastID = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock {
            lastID += 1
            return lastID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            let cancelled: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time on and wakes every sleeper whose deadline has come, earliest
    /// first.
    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// The end of a test: wakes whatever is still asleep, the way a cancel would.
    func cancelSleepers() {
        let all: [Sleeper] = lock.withLock {
            defer { sleepers = [] }
            return sleepers
        }
        for sleeper in all { sleeper.continuation.resume(throwing: CancellationError()) }
    }
}

/// What the mock host reports as a failure: the driver's own kinds, or the
/// attach's error.
enum MockFailure: Equatable {
    case kind(AutoAttachFailureKind)
    case attach(String)
}

/// The app side of a run, recorded. A test waits for what it expects with
/// `waitUntil` rather than counting yields, and can hold an attempt or the
/// target-list read in flight to put the deadline in the middle of it.
@MainActor
final class MockHost: AutoAttachHost {
    typealias Failure = MockFailure

    var targets: [TargetRecord]
    var attachedTargetIDs: Set<String> = []
    var busy: Set<String> = []
    var setupReady = true
    var mounts: [MountTableEntry] = []
    let home = "/Users/b"

    /// What each attach answers, in order; the last one repeats. nil attaches.
    var outcomes: [String: [MockFailure?]] = [:]
    /// Targets whose next attach waits for `release`.
    var holdNextAttach: Set<String> = []
    /// Answers to `readTargets`, in order; the last one repeats.
    var readAnswers: [Bool] = [true]
    /// The next `readTargets` waits for `releaseRead`.
    var holdNextRead = false

    private(set) var reads = 0
    private(set) var attachCalls: [String] = []
    private(set) var failuresMade: [AutoAttachFailureKind] = []
    private(set) var recorded: [String: MockFailure] = [:]
    private(set) var clears: [String] = []
    private(set) var windowsShown = 0
    private(set) var activitiesBegun = 0
    private(set) var activitiesEnded = 0
    private(set) var finishes = 0
    private(set) var logs: [String] = []
    /// The driver under test. Its tasks hold it weakly, as the app's
    /// `AutoAttacher` does; something has to own it for the test's length.
    var driver: AnyObject?

    private var heldAttaches: [String: CheckedContinuation<MockFailure?, Never>] = [:]
    private var heldRead: CheckedContinuation<Bool, Never>?
    private var waiters: [(id: Int, condition: @MainActor () -> Bool,
                           continuation: CheckedContinuation<Void, Never>)] = []
    private var lastWaiterID = 0

    init(targets: [TargetRecord]) {
        self.targets = targets
    }

    // MARK: Driving the test

    /// Returns once `condition` holds, or when the test is cancelled — a time
    /// limit has to be able to end a test whose condition never comes true.
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        lastWaiterID += 1
        let id = lastWaiterID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters.append((id, condition, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.abandonWaiter(id) }
        }
    }

    private func abandonWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    func isHeld(_ targetID: String) -> Bool { heldAttaches[targetID] != nil }
    var isReadHeld: Bool { heldRead != nil }

    func release(_ targetID: String, with outcome: MockFailure?) {
        heldAttaches.removeValue(forKey: targetID)?.resume(returning: outcome)
    }

    func releaseRead(_ answer: Bool) {
        heldRead?.resume(returning: answer)
        heldRead = nil
    }

    /// For `start`'s `onFinish`.
    func finished() {
        finishes += 1
        changed()
    }

    private func changed() {
        var ready: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            guard waiter.condition() else { return false }
            ready.append(waiter.continuation)
            return true
        }
        for continuation in ready { continuation.resume() }
    }

    // MARK: AutoAttachHost

    func readTargets() async -> Bool {
        reads += 1
        changed()
        if holdNextRead {
            holdNextRead = false
            return await withCheckedContinuation { continuation in
                heldRead = continuation
                changed()
            }
        }
        return readAnswers.count > 1 ? readAnswers.removeFirst() : readAnswers.first ?? true
    }

    func isBusy(_ targetID: String) -> Bool { busy.contains(targetID) }

    func ensureSetupReady() async -> Bool { setupReady }

    func mountTable() -> [MountTableEntry] { mounts }

    func attach(_ target: TargetRecord) async -> MockFailure? {
        attachCalls.append(target.id)
        changed()
        if holdNextAttach.remove(target.id) != nil {
            return await withCheckedContinuation { continuation in
                heldAttaches[target.id] = continuation
                changed()
            }
        }
        var queue = outcomes[target.id] ?? [nil]
        let outcome = queue.count > 1 ? queue.removeFirst() : queue.first ?? nil
        outcomes[target.id] = queue
        return outcome
    }

    func failure(_ kind: AutoAttachFailureKind, displayName: String) -> MockFailure {
        failuresMade.append(kind)
        changed()
        return .kind(kind)
    }

    func message(of failure: MockFailure) -> String { String(describing: failure) }

    func recordFailures(_ failures: [String: MockFailure]) {
        recorded.merge(failures) { _, new in new }
        changed()
    }

    func clearFailure(for targetID: String) {
        recorded[targetID] = nil
        clears.append(targetID)
        changed()
    }

    func hasRecordedFailure(for targetID: String) -> Bool { recorded[targetID] != nil }

    func showWindow() {
        windowsShown += 1
        changed()
    }

    func beginActivity() {
        activitiesBegun += 1
        changed()
    }

    func endActivity() {
        activitiesEnded += 1
        changed()
    }

    func log(_ message: String) { logs.append(message) }
}
