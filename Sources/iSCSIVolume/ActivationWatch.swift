//
//  ActivationWatch.swift
//  When the extension gives up on a resource FSKit loaded and never activated.
//
//  `mount -F` loads the resource, then activates the volume the load returned:
//  4–6 ms apart in every trace on the 26.6 VM. FSKit never sends
//  `unloadResource`, not even on a normal detach, so a load whose activate
//  never comes is never undone. That happened at a login on 2026-10-22: the
//  first extension launch failed, fskitd refused the next mount's activate
//  ("previous task is running"), and the instance kept the loaded resource and
//  its daemon session with nothing mounted. While it did, fskitd refused every
//  new mount of that resource ("resource state is 4").
//
//  Each load gets its own extension instance, so the instance exits once the
//  grace period passes. An instance that has activated anything is serving a
//  volume and is never given up.
//
//  Pure, so it is testable without waiting: the extension supplies the times.
//

public struct ActivationWatch: Sendable {
    /// Wide against the milliseconds a real activate takes; short against the
    /// 5 min an attach-at-login run keeps retrying.
    public static let grace: Duration = .seconds(30)

    private let grace: Duration
    private var firstLoad: ContinuousClock.Instant?
    private var hasActivated = false

    public init(grace: Duration = Self.grace) {
        self.grace = grace
    }

    public mutating func loaded(at now: ContinuousClock.Instant) {
        if firstLoad == nil { firstLoad = now }
    }

    public mutating func activated() {
        hasActivated = true
    }

    public func shouldGiveUp(at now: ContinuousClock.Instant) -> Bool {
        guard !hasActivated, let firstLoad else { return false }
        return now - firstLoad >= grace
    }
}
