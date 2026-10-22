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

@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// While the login item is on, macOS must not also relaunch the app through
    /// "Reopen windows when logging back in". That relaunch is either a second,
    /// non-login launch — which skips auto-attach — or, reaching the windowless
    /// login instance, a reopen that opens the window. One launch at login, and
    /// it is the login item's.
    static func applyRelaunchPolicy() {
        if status == .enabled {
            NSApp.disableRelaunchOnLogin()
        } else {
            NSApp.enableRelaunchOnLogin()
        }
    }
}
