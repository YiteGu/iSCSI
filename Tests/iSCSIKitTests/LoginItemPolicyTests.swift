import Testing
@testable import iSCSIKit

/// When the app registers itself as a login item, and when it takes itself
/// back out. The case that matters most is the one where it does nothing: a
/// user who turned the item off in System Settings keeps it off.
@Suite("Login item policy")
struct LoginItemPolicyTests {

    private func action(saved: Bool?, anyMarked: Bool, registered: Bool, enabled: Bool,
                        canRegister: Bool = true) -> LoginItemPolicy.Action {
        LoginItemPolicy.action(savedIsMarked: saved, anyMarked: anyMarked,
                               isRegistered: registered, isEnabled: enabled,
                               canRegisterFromHere: canRegister)
    }

    @Test("saving a marked target registers")
    func savingAMarkedTargetRegisters() {
        #expect(action(saved: true, anyMarked: true, registered: false, enabled: false) == .register)
    }

    @Test("saving an unmarked target never re-registers an item the user turned off")
    func unrelatedSaveNeverRegisters() {
        #expect(action(saved: false, anyMarked: true, registered: true, enabled: false) == .none)
    }

    @Test("saving a marked target while already enabled does nothing")
    func markedSaveWhileEnabledDoesNothing() {
        #expect(action(saved: true, anyMarked: true, registered: true, enabled: true) == .none)
    }

    @Test("unchecking the last marked target unregisters")
    func lastUnmarkUnregisters() {
        #expect(action(saved: false, anyMarked: false, registered: true, enabled: true) == .unregister)
    }

    @Test("removing the last marked target unregisters")
    func deleteOfLastMarkedUnregisters() {
        #expect(action(saved: nil, anyMarked: false, registered: true, enabled: true) == .unregister)
    }

    @Test("nothing marked and nothing registered does nothing")
    func nothingMarkedNothingRegisteredDoesNothing() {
        #expect(action(saved: false, anyMarked: false, registered: false, enabled: false) == .none)
    }

    // NSApp's relaunch-on-login switch is a counter, not a setting.

    @Test("a launch with the login item off touches nothing")
    func launchWithItemOffMakesNoCall() {
        #expect(LoginItemPolicy.relaunchChange(loginItemEnabled: false, relaunchDisabled: false)
                == .none)
    }

    @Test("an enabled login item disables relaunch once")
    func enabledItemDisablesRelaunchOnce() {
        #expect(LoginItemPolicy.relaunchChange(loginItemEnabled: true, relaunchDisabled: false)
                == .disable)
        #expect(LoginItemPolicy.relaunchChange(loginItemEnabled: true, relaunchDisabled: true)
                == .none)
    }

    @Test("turning the login item off undoes exactly its own disable")
    func turningOffUndoesTheDisable() {
        #expect(LoginItemPolicy.relaunchChange(loginItemEnabled: false, relaunchDisabled: true)
                == .enable)
    }

    @Test("a copy outside /Applications does not register")
    func outsideApplicationsIsBlocked() {
        #expect(action(saved: true, anyMarked: true, registered: false, enabled: false,
                       canRegister: false) == .blockedByLocation)
    }
}
