import CoreServices
import Foundation
import Testing
@testable import iSCSIKit

/// Which launches are login launches. Measured on the 26.6 VM with a probe
/// registered through `SMAppService.mainApp` (2026-10-22): a login item gets
/// an open-application event whose property data is 'lgit'; a manual launch
/// gets the same event without it.
@Suite("Login launch")
struct LoginLaunchTests {

    /// 'GURL', the class and ID of the get-URL event, which CoreServices does
    /// not export to Swift.
    private static let getURL: FourCharCode = 0x4755_524C

    private func appleEvent(_ eventClass: AEEventClass, _ eventID: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
    }

    private func openApplication(marked marker: OSType? = nil) -> NSAppleEventDescriptor {
        let event = appleEvent(AEEventClass(kCoreEventClass), AEEventID(kAEOpenApplication))
        if let marker {
            event.setParam(NSAppleEventDescriptor(enumCode: marker),
                           forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    @Test("an open-application event marked as a login item launch is one")
    func loginItemLaunch() {
        #expect(LoginLaunch.isLoginItemLaunch(openApplication(marked: OSType(keyAELaunchedAsLogInItem))))
    }

    @Test("a launch by hand carries no mark and is not one")
    func manualLaunch() {
        #expect(!LoginLaunch.isLoginItemLaunch(openApplication()))
    }

    @Test("an open-application event with some other mark is not one")
    func otherMark() {
        #expect(!LoginLaunch.isLoginItemLaunch(openApplication(marked: OSType(keyAELaunchedAsServiceItem))))
    }

    @Test("no event at all is not one")
    func noEvent() {
        #expect(!LoginLaunch.isLoginItemLaunch(nil))
    }

    @Test("a launch to open the main window by URL is not one")
    func urlLaunch() {
        // Anything can open the window's URL while the app is not running. That
        // launch must take the by-hand path: the window, and no attach.
        let event = appleEvent(Self.getURL, Self.getURL)
        event.setParam(NSAppleEventDescriptor(string: MainWindowLink.url.absoluteString),
                       forKeyword: AEKeyword(keyDirectObject))
        #expect(!LoginLaunch.isLoginItemLaunch(event))
    }
}

/// The URL that opens the main window from the background, where a hidden menu
/// bar item's label cannot.
@Suite("Main window link")
struct MainWindowLinkTests {

    @Test("the app's Info.plist declares the scheme the link uses")
    func infoPlistDeclaresTheScheme() throws {
        // A rename on either side would not fail any build: the window would
        // simply stop opening at the end of a run with the menu bar item hidden.
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // iSCSIKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("apps/iSCSIApp/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(MainWindowLink.scheme))
    }

    @Test("the link names the window and carries nothing else")
    func linkCarriesNothingElse() {
        // Any app or web page can open it, so it must not be able to say
        // anything but "show the window".
        let url = MainWindowLink.url
        #expect(url.scheme == MainWindowLink.scheme)
        #expect(url.host() == MainWindowLink.host)
        #expect(url.path().isEmpty)
        #expect(url.query() == nil)
        #expect(url.fragment() == nil)
    }
}
