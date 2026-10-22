//
//  MenuBarLabel.swift
//  The menu bar icon, and the one place the main window is opened from
//  outside a window.
//
//  The window is `.suppressed` at launch and `openWindow` only exists inside a
//  view. This label is the only view that is always alive — at login there is
//  no window at all — so a request to show the window (a manual launch, a Dock
//  click, an auto-attach run that ended with failures) is a flag on the model
//  that this view acts on.
//

import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The icon carries the state: a filled drive when something is
        // mounted, a warning when setup is incomplete. For most users on
        // most days this is the only part of the app they look at.
        Image(systemName: symbol)
            .onChange(of: model.wantsMainWindow, initial: true) { _, wants in
                guard wants else { return }
                model.wantsMainWindow = false
                openWindow(id: "main")
                NSApp.activate()
            }
    }

    private var symbol: String {
        if !model.isReady { return "externaldrive.badge.exclamationmark" }
        return model.attachments.attachments.contains(where: \.isFullyAttached)
            ? "externaldrive.fill.badge.checkmark"
            : "externaldrive"
    }
}
