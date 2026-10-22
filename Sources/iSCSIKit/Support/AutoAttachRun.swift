//
//  AutoAttachRun.swift
//  What to attach at login, when to try again, and when to give up.
//
//  The app attaches every target marked "Attach at login" when it is launched
//  as a login item. Storage is often not reachable yet at that moment — Wi-Fi
//  still joining, the NAS still booting after a power cut — so a target that
//  fails is retried silently, every 15 s for 5 min, and only what is still
//  unattached after that is put in front of the user.
//
//  Decided here, purely, so the schedule is testable without a clock: every
//  time is an offset from the start of the run, and the app supplies them.
//  See docs/superpowers/specs/2026-10-22-auto-attach-at-login-design.md.
//

import Foundation

public struct AutoAttachRun: Sendable, Equatable {
    /// Start to start, per target.
    public static let interval: Duration = .seconds(15)
    /// No attempt starts after this. It also ends the run, even with an
    /// attempt in flight: a `mount -F` under a wedged target can hang for good.
    public static let budget: Duration = .seconds(300)

    /// Why a target is still unattached when the run ends.
    public enum Failure: Sendable, Equatable {
        case lastAttemptFailed
        /// An attempt was in flight at the deadline. It is left running.
        case stillAttaching
    }

    private enum State: Sendable, Equatable {
        case waiting(lastStart: Duration?)
        case attempting(since: Duration)
        case attached
        /// The user took the target over: attached, detached, removed or
        /// unchecked it. Never retried, never a failure.
        case cancelled
    }

    private let order: [String]
    private var states: [String: State]
    private let interval: Duration
    private let budget: Duration

    public init(targetIDs: [String], interval: Duration = Self.interval,
                budget: Duration = Self.budget) {
        order = targetIDs
        states = Dictionary(targetIDs.map { ($0, State.waiting(lastStart: nil)) },
                            uniquingKeysWith: { first, _ in first })
        self.interval = interval
        self.budget = budget
    }

    public func canStart(_ id: String, at now: Duration) -> Bool {
        guard now < budget, case .waiting(let lastStart) = states[id] else { return false }
        guard let lastStart else { return true }
        return now >= lastStart + interval
    }

    public mutating func started(_ id: String, at now: Duration) {
        guard case .waiting = states[id] else { return }
        states[id] = .attempting(since: now)
    }

    /// Ignored for a target that was cancelled meanwhile: a late result must
    /// not bring back something the user has already acted on.
    public mutating func finished(_ id: String, attached: Bool) {
        guard case .attempting(let since) = states[id] else { return }
        states[id] = attached ? .attached : .waiting(lastStart: since)
    }

    public mutating func cancel(_ id: String) {
        guard states[id] != nil else { return }
        states[id] = .cancelled
    }

    /// The app is being removed: nothing more may start.
    public mutating func cancelAll() {
        for id in order { states[id] = .cancelled }
    }

    /// When `id` may next start, or nil if it never will again.
    public func nextStart(for id: String) -> Duration? {
        guard case .waiting(let lastStart) = states[id] else { return nil }
        let next = lastStart.map { $0 + interval } ?? .zero
        return next < budget ? next : nil
    }

    public func isOver(at now: Duration) -> Bool {
        now >= budget || states.values.allSatisfy { $0 == .attached || $0 == .cancelled }
    }

    /// Every target that is neither attached nor cancelled. Meaningful once
    /// `isOver`.
    public var failures: [String: Failure] {
        var result: [String: Failure] = [:]
        for id in order {
            switch states[id] {
            case .waiting: result[id] = .lastAttemptFailed
            case .attempting: result[id] = .stillAttaching
            default: break
            }
        }
        return result
    }

    /// Marked targets this user does not already have attached, in list order.
    /// `excluding` holds targets the user took over before the run could begin
    /// — a cancel that arrives while the target list is still being read has
    /// no run to land in, and must not be lost.
    public static func pendingTargetIDs(_ targets: [TargetRecord],
                                        attachedTargetIDs: Set<String>,
                                        excluding: Set<String>) -> [String] {
        targets.filter {
            $0.autoAttach && !attachedTargetIDs.contains($0.id) && !excluding.contains($0.id)
        }.map(\.id)
    }

    /// Another login session on this Mac is using the target.
    ///
    /// `autoAttach` lives in the daemon's machine-wide `targets.json`, but the
    /// login item and the mounts are per user, so under fast user switching a
    /// second user's login could mount a volume the first has mounted — two
    /// independent writers on one APFS volume. A daemon session for the target
    /// that none of this user's mounts accounts for is someone else's.
    /// Sessions die with the client that opened them, so a live one is a live
    /// user, not a leftover from this user's last login.
    ///
    /// "This user's mounts" is the attachment list *and* the mount table, by
    /// `MountpointTag`: an attach whose `mount -F` succeeded but whose image
    /// layer failed leaves a mount, holding a session, that never reached the
    /// attachment list — and that session is ours.
    public static func isInUseElsewhere(_ target: TargetRecord, sessions: [SessionInfo],
                                        attachedTargetIDs: Set<String>,
                                        mountedTags: Set<String>) -> Bool {
        guard !attachedTargetIDs.contains(target.id) else { return false }
        let tag = MountpointTag.derive(
            portal: MountpointTag.portal(host: target.host, port: target.port),
            targetIQN: target.targetIQN, lun: target.lun)
        guard !mountedTags.contains(tag) else { return false }
        return sessions.contains { $0.targetIQN == target.targetIQN && $0.lun == target.lun }
    }
}
