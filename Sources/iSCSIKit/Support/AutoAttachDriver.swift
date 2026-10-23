//
//  AutoAttachDriver.swift
//  Drives an attach-at-login run: one loop per target, on `AutoAttachRun`'s
//  schedule, for five minutes.
//
//  Everything with an effect goes through `AutoAttachHost`, and time through
//  the injected clock, so the run is tested without a daemon, a mount table or
//  a five-minute wait. The app's `AutoAttacher` is the host.
//
//  One loop per target, so one slow target does not hold up the others. The
//  loop is cancelled only to cut its sleep short; it stops because the run says
//  the target may not start again. The attempt itself runs in its own task, so
//  a cancel never reaches a mount half-way through an XPC call: it finishes,
//  and the run ignores what it says.
//
//  See docs/superpowers/specs/2026-10-22-auto-attach-at-login-design.md.
//

import Foundation

/// Why an attempt did not attach, when the attach itself never ran.
public enum AutoAttachFailureKind: Sendable, Equatable {
    case setupNotReady
    case inUseElsewhere
    /// The run ended with this target's attempt still under way.
    case stillAttaching
}

/// The app side of a run.
@MainActor
public protocol AutoAttachHost: AnyObject {
    /// The app's description of a failure, shown on the target's row.
    associatedtype Failure: Sendable

    /// Reads the target list. False while it cannot be read or setup is not
    /// ready.
    func readTargets() async -> Bool
    var targets: [TargetRecord] { get }
    /// Targets this user has attached all the way, device and all.
    var attachedTargetIDs: Set<String> { get }
    /// A manual Attach or Detach of this target is under way.
    func isBusy(_ targetID: String) -> Bool
    /// Checks setup again if it is not ready; true once it is.
    func ensureSetupReady() async -> Bool
    func mountTable() -> [MountTableEntry]
    /// This user's home directory, as mount points under it are recorded.
    var home: String { get }
    /// nil when the target attached.
    func attach(_ target: TargetRecord) async -> Failure?
    func failure(_ kind: AutoAttachFailureKind, displayName: String) -> Failure
    func message(of failure: Failure) -> String
    func recordFailures(_ failures: [String: Failure])
    func clearFailure(for targetID: String)
    func hasRecordedFailure(for targetID: String) -> Bool
    /// Shows the main window, from the background if need be.
    func showWindow()
    /// Keeps App Nap off for as long as the run lasts.
    func beginActivity()
    func endActivity()
    func log(_ message: String)
}

@MainActor
public final class AutoAttachDriver<Host: AutoAttachHost, C: Clock> where C.Duration == Duration {
    public private(set) var isRunning = false

    private unowned let host: Host
    private let clock: C
    private var run = AutoAttachRun(targetIDs: [])
    private var concluded = false
    /// Whether the target list was ever read. If not, the run ends with the
    /// window open on whatever Setup says is wrong.
    private var listRead = false
    private var startedAt: C.Instant
    private var loops: [String: Task<Void, Never>] = [:]
    private var deadline: Task<Void, Never>?
    private var lastErrors: [String: Host.Failure] = [:]
    private var onFinish: (@MainActor () -> Void)?
    /// Every target the user has acted on since launch. Kept apart from `run`
    /// because a cancel can arrive while the target list is still being read,
    /// before there is a run for it to land in.
    private var takenOver: Set<String> = []

    public init(host: Host, clock: C) {
        self.host = host
        self.clock = clock
        startedAt = clock.now
    }

    private var elapsed: Duration { startedAt.duration(to: clock.now) }

    public func start(onFinish: @escaping @MainActor () -> Void) {
        guard !isRunning, !concluded else { return }
        isRunning = true
        self.onFinish = onFinish
        startedAt = clock.now
        host.beginActivity()
        host.log("run started")
        let end = startedAt.advanced(by: AutoAttachRun.budget)
        let clock = clock
        deadline = Task { [weak self] in
            try? await clock.sleep(until: end, tolerance: nil)
            self?.conclude()
        }
        Task { [weak self] in await self?.readTargetsThenAttach() }
    }

    /// The user acted on this target — attached, detached, removed or unchecked
    /// it. It is never tried again by this run and is not a failure.
    public func cancel(targetID id: String) {
        takenOver.insert(id)
        run.cancel(id)
        loops[id]?.cancel()
        loops[id] = nil
        // That may have been the last one outstanding.
        if isRunning, listRead, run.isOver(at: elapsed) { conclude() }
    }

    /// The app is being removed: stop for good, without the window. Attempts
    /// already in flight finish; nothing new starts.
    public func cancelAll() {
        run.cancelAll()
        for loop in loops.values { loop.cancel() }
        loops = [:]
        guard isRunning else { return }
        concluded = true
        isRunning = false
        deadline?.cancel()
        host.endActivity()
        onFinish = nil
        host.log("run stopped for uninstall")
    }

    // MARK: - The run

    private func readTargetsThenAttach() async {
        while !concluded {
            if await host.readTargets() { break }
            try? await clock.sleep(until: clock.now.advanced(by: AutoAttachRun.interval),
                                   tolerance: nil)
        }
        guard !concluded else { return }
        listRead = true

        let pending = AutoAttachRun.pendingTargetIDs(host.targets,
                                                     attachedTargetIDs: host.attachedTargetIDs,
                                                     excluding: takenOver)
        run = AutoAttachRun(targetIDs: pending)
        host.log("\(pending.count) marked target(s) to attach")
        if run.isOver(at: elapsed) { conclude(); return }
        for id in pending {
            loops[id] = Task { [weak self] in await self?.loop(id) }
        }
    }

    private func loop(_ id: String) async {
        while run.canStart(id, at: elapsed) {
            guard let target = host.targets.first(where: { $0.id == id }) else {
                run.cancel(id)
                break
            }
            // Busy before our attempt has started means a manual Attach or
            // Detach is under way: the user has it, and two attaches of one
            // target would race `mount -F` on one path.
            if host.isBusy(id) {
                cancel(targetID: id)
                break
            }
            run.started(id, at: elapsed)
            // Its own task: cancelling this loop must not reach the attempt.
            let failure = await Task { await self.attemptOnce(target) }.value
            finish(target, failure: failure)
            guard let next = run.nextStart(for: id) else { break }
            try? await clock.sleep(until: startedAt.advanced(by: next), tolerance: nil)
        }
    }

    /// nil when the target attached.
    private func attemptOnce(_ target: TargetRecord) async -> Host.Failure? {
        guard await host.ensureSetupReady() else {
            return host.failure(.setupNotReady, displayName: target.displayName)
        }
        if AutoAttachRun.isInUseElsewhere(target, mounts: host.mountTable(), home: host.home) {
            return host.failure(.inUseElsewhere, displayName: target.displayName)
        }
        return await host.attach(target)
    }

    private func finish(_ target: TargetRecord, failure: Host.Failure?) {
        let id = target.id
        run.finished(id, attached: failure == nil)
        if let failure {
            lastErrors[id] = failure
            host.log("“\(target.displayName)” not attached: \(host.message(of: failure))")
            // An attempt that outlived the run: its real error replaces
            // "still trying", unless the user has dealt with the target since.
            if concluded, host.hasRecordedFailure(for: id) {
                host.recordFailures([id: failure])
            }
        } else {
            host.log("“\(target.displayName)” attached")
            host.clearFailure(for: id)
        }
        if !concluded, run.isOver(at: elapsed) { conclude() }
    }

    private func conclude() {
        guard isRunning, !concluded else { return }
        concluded = true
        isRunning = false
        deadline?.cancel()
        host.endActivity()

        var failures: [String: Host.Failure] = [:]
        for (id, failure) in run.failures {
            let name = host.targets.first(where: { $0.id == id })?.displayName ?? id
            switch failure {
            case .stillAttaching:
                failures[id] = host.failure(.stillAttaching, displayName: name)
            case .lastAttemptFailed:
                failures[id] = lastErrors[id] ?? host.failure(.stillAttaching, displayName: name)
            }
        }
        host.recordFailures(failures)
        if !failures.isEmpty || !listRead { host.showWindow() }
        host.log("run over: \(failures.count) not attached; target list read: \(listRead)")
        onFinish?()
        onFinish = nil
    }
}
