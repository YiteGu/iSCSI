//
//  LoginItemPolicy.swift
//  When the app registers itself as a login item, and when it takes itself out.
//
//  The login item follows the "Attach at login" checkboxes: there is no
//  separate "Open at login" setting to disagree with them. Registration
//  happens only on the user's own save of a checked target — never on launch,
//  never on an unrelated edit — so someone who turned the item off in System
//  Settings keeps it off until they check a box again. Unregistration happens
//  as soon as nothing is marked.
//

import Foundation

public enum LoginItemPolicy {
    public enum Action: Sendable, Equatable {
        case register, unregister
        /// Would register, but this copy is translocated or outside
        /// /Applications, where a registration points at a path that may not
        /// be there next time.
        case blockedByLocation
        case none
    }

    /// - Parameters:
    ///   - savedIsMarked: the record the user just saved has the box checked;
    ///     nil for a delete.
    ///   - anyMarked: any target in the daemon's list after the change is marked.
    ///   - isRegistered: `SMAppService.mainApp.status` is `.enabled` or
    ///     `.requiresApproval`.
    ///   - isEnabled: the status is `.enabled`.
    ///   - canRegisterFromHere: in /Applications and not translocated.
    public static func action(savedIsMarked: Bool?, anyMarked: Bool, isRegistered: Bool,
                              isEnabled: Bool, canRegisterFromHere: Bool) -> Action {
        if !anyMarked && isRegistered { return .unregister }
        if savedIsMarked == true && !isEnabled {
            return canRegisterFromHere ? .register : .blockedByLocation
        }
        return .none
    }

    public enum RelaunchChange: Sendable, Equatable { case disable, enable, none }

    /// While the login item is on, the app must not also be relaunched at login
    /// by "Reopen windows when logging back in": that second, non-login launch
    /// skips auto-attach and shows the window. AppKit's switch for this is a
    /// counter, not a setting — each `disableRelaunchOnLogin()` has to be undone
    /// by exactly one `enableRelaunchOnLogin()`, and an `enable` with nothing to
    /// undo leaves the app over-enabled. So disable once, on the way into
    /// "enabled", and enable only to undo that.
    public static func relaunchChange(loginItemEnabled: Bool,
                                      relaunchDisabled: Bool) -> RelaunchChange {
        switch (loginItemEnabled, relaunchDisabled) {
        case (true, false): return .disable
        case (false, true): return .enable
        default: return .none
        }
    }
}
