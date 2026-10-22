//
//  LoginItem.swift
//  The app as its own login item, for "Attach at login".
//
//  `SMAppService.mainApp`, so no plist: the app is launched at login the way
//  Login Items launches any app, and the launch event says so (see
//  AppDelegate). When to register is `LoginItemPolicy`'s call.
//

import AppKit
import ServiceManagement
import iSCSIKit

@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// The same gate the daemon's registration has: a translocated copy runs
    /// from a path that vanishes when it quits, and one outside /Applications
    /// is usually a stray (Downloads, a mounted DMG) — a login item pointing
    /// there launches the wrong copy or nothing.
    static var canRegisterFromHere: Bool {
        let location = InstallLocation()
        return location.isInApplications && !location.isTranslocated
    }

    static func register() throws {
        defer { applyRelaunchPolicy() }
        try SMAppService.mainApp.register()
    }

    static func unregister() async throws {
        defer { applyRelaunchPolicy() }
        try await SMAppService.mainApp.unregister()
    }

    /// Whether this process has called `disableRelaunchOnLogin()` and not yet
    /// undone it. AppKit keeps a counter, so the calls must pair up exactly.
    private static var relaunchDisabled = false

    /// While the login item is on, macOS must not also relaunch the app through
    /// "Reopen windows when logging back in". That relaunch is either a second,
    /// non-login launch — which skips auto-attach — or, reaching the windowless
    /// login instance, a reopen that opens the window. One launch at login, and
    /// it is the login item's. `LoginItemPolicy.relaunchChange` has the rule.
    static func applyRelaunchPolicy() {
        switch LoginItemPolicy.relaunchChange(loginItemEnabled: status == .enabled,
                                              relaunchDisabled: relaunchDisabled) {
        case .disable:
            NSApp.disableRelaunchOnLogin()
            relaunchDisabled = true
        case .enable:
            NSApp.enableRelaunchOnLogin()
            relaunchDisabled = false
        case .none:
            break
        }
    }
}
