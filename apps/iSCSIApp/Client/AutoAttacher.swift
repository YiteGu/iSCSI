//
//  AutoAttacher.swift
//  Attaching marked targets after a login launch, silently, for five minutes.
//
//  Storage is often not reachable the moment a user logs in — Wi-Fi still
//  joining, the NAS still booting after a power cut — so each marked target is
//  retried every 15 s for up to 5 min with nothing on screen. Only what is still
//  unattached after that is shown: the main window opens with a warning on those
//  rows. When and whether to try is `AutoAttachRun`'s call; this drives it.
//
//  Each attempt runs the whole path — setup, connection test, mount — because
//  any of the daemon, the network and `fskit_agent` can be late at login.
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
import iSCSIKit
import os

private let autoAttachLog = Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "autoattach")

@MainActor
final class AutoAttacher {
    static let inUseMessage = "In use by another session on this Mac."
    static let inUseSuggestion = "Attaching it from two accounts at once would corrupt it. "
        + "Eject it in the other account, then attach it here."
    static let stillAttachingMessage = "Still trying to attach after 5 minutes."
    static let stillAttachingSuggestion = "It will appear by itself if the target answers. "
        + "Otherwise check the target and press Attach."
    static let setupMessage = "Setup is not finished."
    static let setupSuggestion = "Open the Setup screen to see what is missing."

    static func failureTitle(_ name: String) -> String {
        "Could not attach “\(name)” at login"
    }

    private unowned let model: AppModel
    private(set) var isRunning = false

    private var run = AutoAttachRun(targetIDs: [])
    private var concluded = false
    /// Whether the target list was ever read. If not, the run ends with the
    /// window open on whatever Setup says is wrong.
    private var listRead = false
    private let clock = ContinuousClock()
    private var startedAt = ContinuousClock.now
    private var loops: [String: Task<Void, Never>] = [:]
    private var deadline: Task<Void, Never>?
    private var lastErrors: [String: PresentableError] = [:]
    private var onFinish: (@MainActor () -> Void)?
    /// Every target the user has acted on since launch. Kept apart from `run`
    /// because a cancel can arrive while the target list is still being read,
    /// before there is a run for it to land in.
    private var takenOver: Set<String> = []

    init(model: AppModel) { self.model = model }

    private var elapsed: Duration { clock.now - startedAt }

    func start(onFinish: @escaping @MainActor () -> Void) {
        guard !isRunning, !concluded else { return }
        isRunning = true
        self.onFinish = onFinish
        startedAt = clock.now
        autoAttachLog.info("run started")
        let end = startedAt + AutoAttachRun.budget
        deadline = Task { [weak self] in
            try? await Task.sleep(until: end, clock: .continuous)
            self?.conclude()
        }
        Task { [weak self] in await self?.readTargetsThenAttach() }
    }

    /// The user acted on this target — attached, detached, removed or unchecked
    /// it. It is never tried again by this run and is not a failure.
    func cancel(targetID id: String) {
        takenOver.insert(id)
        run.cancel(id)
        loops[id]?.cancel()
        loops[id] = nil
        // That may have been the last one outstanding.
        if isRunning, listRead, run.isOver(at: elapsed) { conclude() }
    }

    /// The app is being removed: stop for good, without the window or
    /// Sparkle. Attempts already in flight finish; nothing new starts.
    func cancelAll() {
        run.cancelAll()
        for loop in loops.values { loop.cancel() }
        loops = [:]
        guard isRunning else { return }
        concluded = true
        isRunning = false
        deadline?.cancel()
        onFinish = nil
        autoAttachLog.info("run stopped for uninstall")
    }

    // MARK: - The run

    private func readTargetsThenAttach() async {
        while !concluded {
            if await model.refresh(reportingErrors: false), model.isReady { break }
            autoAttachLog.info("target list not readable yet; setup ready: \(self.model.isReady)")
            try? await Task.sleep(for: AutoAttachRun.interval)
        }
        guard !concluded else { return }
        listRead = true

        // Half-attached (FSKit mount up, no device) stays pending: attach is
        // idempotent and completes it.
        let attached = Set(model.attachments.attachments.filter { $0.device != nil }
            .map(\.targetID))
        let pending = AutoAttachRun.pendingTargetIDs(model.targets, attachedTargetIDs: attached,
                                                     excluding: takenOver)
        run = AutoAttachRun(targetIDs: pending)
        autoAttachLog.info("\(pending.count) marked target(s) to attach")
        if run.isOver(at: elapsed) { conclude(); return }
        for id in pending {
            loops[id] = Task { [weak self] in await self?.loop(id) }
        }
    }

    private func loop(_ id: String) async {
        while run.canStart(id, at: elapsed) {
            guard let target = model.targets.first(where: { $0.id == id }) else {
                run.cancel(id)
                break
            }
            // Busy before our attempt has started means a manual Attach or
            // Detach is under way: the user has it, and two attaches of one
            // target would race `mount -F` on one path.
            if model.busy.contains(id) {
                cancel(targetID: id)
                break
            }
            run.started(id, at: elapsed)
            // Its own task: cancelling this loop must not reach the attempt.
            let failure = await Task { await self.attemptOnce(target) }.value
            finish(target, failure: failure)
            guard let next = run.nextStart(for: id) else { break }
            try? await Task.sleep(until: startedAt + next, clock: .continuous)
        }
    }

    /// nil when the target attached.
    private func attemptOnce(_ target: TargetRecord) async -> PresentableError? {
        let title = Self.failureTitle(target.displayName)
        if !model.isReady { await model.setup.checkAll() }
        guard model.isReady else {
            return PresentableError(title: title, message: Self.setupMessage,
                                    suggestion: Self.setupSuggestion)
        }
        do {
            // Every mount of this user's counts as ours: recorded attachments,
            // and FSKit mounts an earlier attempt left without recording.
            let ours = Set(model.attachments.attachments.map(\.targetID))
            let mounted = AttachmentManager.mountedTags(of: [target])
            let sessions = try await DaemonConnection.sessions()
            if AutoAttachRun.isInUseElsewhere(target, sessions: sessions, attachedTargetIDs: ours,
                                              mountedTags: mounted) {
                return PresentableError(title: title, message: Self.inUseMessage,
                                        suggestion: Self.inUseSuggestion)
            }
            _ = try await model.withBusy(target.id) { try await model.performAttach(target) }
            return nil
        } catch AttachmentError.blankLUN {
            // Attached, just not formatted: the row says so. Not a failure.
            return nil
        } catch {
            return AppModel.presentable(error, title: title)
        }
    }

    private func finish(_ target: TargetRecord, failure: PresentableError?) {
        let id = target.id
        run.finished(id, attached: failure == nil)
        if let failure {
            lastErrors[id] = failure
            autoAttachLog.info("“\(target.displayName, privacy: .public)” not attached: \(failure.message, privacy: .public)")
            // An attempt that outlived the run: its real error replaces
            // "still trying", unless the user has dealt with the target since.
            if concluded, model.autoAttachFailures[id] != nil {
                model.recordAutoAttachFailures([id: failure])
            }
        } else {
            autoAttachLog.info("“\(target.displayName, privacy: .public)” attached")
            model.clearAutoAttachFailure(for: id)
        }
        if !concluded, run.isOver(at: elapsed) { conclude() }
    }

    private func conclude() {
        guard isRunning, !concluded else { return }
        concluded = true
        isRunning = false
        deadline?.cancel()

        var failures: [String: PresentableError] = [:]
        for (id, failure) in run.failures {
            let name = model.targets.first(where: { $0.id == id })?.displayName ?? id
            switch failure {
            case .stillAttaching:
                failures[id] = PresentableError(title: Self.failureTitle(name),
                                                message: Self.stillAttachingMessage,
                                                suggestion: Self.stillAttachingSuggestion)
            case .lastAttemptFailed:
                failures[id] = lastErrors[id]
                    ?? PresentableError(title: Self.failureTitle(name),
                                        message: Self.stillAttachingMessage,
                                        suggestion: Self.stillAttachingSuggestion)
            }
        }
        model.recordAutoAttachFailures(failures)
        if !failures.isEmpty || !listRead { model.wantsMainWindow = true }
        autoAttachLog.info("run over: \(failures.count) not attached; target list read: \(self.listRead)")
        onFinish?()
        onFinish = nil
    }
}
