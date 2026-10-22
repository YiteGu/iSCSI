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
    /// independent writers on one APFS volume. The mount table is the witness:
    /// every attach starts with an FSKit mount whose source names the target,
    /// on a mount point in the home of the user who made it. One outside this
    /// user's home is someone else's.
    ///
    /// Not the daemon's sessions: they belong to whatever process opened them,
    /// and a process can outlive its use. Measured 2026-10-22 on the 26.6 VM:
    /// fskitd refused the activate that follows a load, the extension kept the
    /// loaded resource and its session with nothing mounted, and every later
    /// attempt read that session as another user.
    ///
    /// The target is matched by name and LUN, not portal: one target reached
    /// through a group address and through its own is still one target.
    public static func isInUseElsewhere(_ target: TargetRecord, mounts: [MountTableEntry],
                                        home: String) -> Bool {
        let ownPrefix = home.hasSuffix("/") ? home : home + "/"
        return mounts.contains { entry in
            guard !entry.on.hasPrefix(ownPrefix),
                  let mounted = mountedTarget(entry.from) else { return false }
            return mounted.lun == target.lun
                && mounted.name.caseInsensitiveCompare(target.targetIQN) == .orderedSame
        }
    }

    /// The target name and LUN in an attach's mount source,
    /// `scheme://portal/<iqn-or-nqn>/<lun-or-nsid>`; nil for any other mount.
    private static func mountedTarget(_ source: String) -> (name: String, lun: UInt64)? {
        guard let url = URL(string: source), url.scheme == "iscsi" || url.scheme == "nvme"
        else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, let lun = UInt64(parts[1]) else { return nil }
        return (String(parts[0]), lun)
    }
}

/// One row of the mount table: what is mounted (`f_mntfromname`) where
/// (`f_mntonname`).
public struct MountTableEntry: Sendable, Equatable {
    public let from: String
    public let on: String

    public init(from: String, on: String) {
        self.from = from
        self.on = on
    }
}
