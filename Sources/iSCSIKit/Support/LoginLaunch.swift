//
//  LoginLaunch.swift
//  Which kind of launch this is, and how the main window is asked for from
//  the background.
//
//  Measured on macOS 26.6.2, SIP on, with a probe registered through
//  `SMAppService.mainApp` (2026-10-22): a login item launch carries an
//  `aevt/oapp` event whose keyAEPropData is 'lgit'; a manual launch carries
//  the same event without it. `currentAppleEvent` is that event in
//  `applicationDidFinishLaunching` and nil in `applicationWillFinishLaunching`.
//

import CoreServices
import Foundation

public enum LoginLaunch {
    /// The open-application event a login item is launched with carries
    /// keyAELaunchedAsLogInItem as its property data. Anything else, a launch
    /// to open a URL included, is not a login launch.
    public static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}

/// The URL that shows the main window.
///
/// A hidden menu bar item's label is not evaluated while the app is in the
/// background, so the end of an attach-at-login run asks for the window by
/// URL as well. The app declares the scheme in its Info.plist, and the
/// `Window` scene handles the host. Anything on the Mac can open this URL, a
/// web page included, so it names the window and carries nothing else.
public enum MainWindowLink {
    public static let scheme = "me.herko.iscsiinitiator"
    public static let host = "main"
    public static var url: URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        return parts.url!
    }
}
