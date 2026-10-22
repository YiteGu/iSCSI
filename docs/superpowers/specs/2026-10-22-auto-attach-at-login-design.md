# Attach at login — design

Approved in conversation 2026-10-22.

## Goal

Targets the user marks **Attach at login** appear in Finder after they log in,
with nothing else on screen. If a marked target cannot be attached, the app keeps
trying quietly for a while. If it still fails, the main window opens with a
warning on that target.

## Decided by the user

- Per-target opt-in. Only targets the user marked attach at login.
- No window at login when everything attaches.
- Unreachable target: retry **every 15 s for up to 5 min, silently**.
- After that, the main window opens with a warning icon next to each marked
  target that is still not attached.
- On a Mac with more than one user, never auto-attach a target another session
  is already using. Show "in use by another session" instead.

## Constraints

- **Attach runs in the app, never the daemon.** `mount -F` resolves the FSKit
  module through the user's `fskit_agent`. This is also why the root daemon
  never needs keychain access before login (`docs/open-questions.md` §7).
- **`targets.json` stays decodable both ways.** Use the existing
  `TargetRecord.autoAttach: Bool`, which every record already carries and
  nothing reads. No new key.
- **No new plist.** The login item is `SMAppService.mainApp`, which needs none.
  The CI plist invariants are untouched.
- The app builds against the macOS 26 SDK. `defaultLaunchBehavior(_:)` and
  `SMAppService.mainApp` are both available there.

## Spike result (2026-10-22, 192.168.64.16, macOS 26.6.2, SIP on)

A throwaway ad-hoc-signed SwiftUI app with a `Window` scene and a
`MenuBarExtra`, registered with `SMAppService.mainApp.register()`:

| Launch | `currentAppleEvent` in `applicationDidFinishLaunching` | Window |
|---|---|---|
| Login item (reboot, auto-login) | `aevt/oapp`, `keyAEPropData` = `'lgit'` | none |
| Manual `open` | `aevt/oapp`, no `keyAEPropData` | opened on request |
| Reopen (Dock click) while windowless | `applicationShouldHandleReopen(hasVisibleWindows: false)` | **SwiftUI did not reopen a `.suppressed` `Window`** |
| Flag flipped 8 s after launch | — | opened on request |

The rules that follow from it:

- **Login launch** = the `oapp` event's `keyAEPropData` enum is
  `keyAELaunchedAsLogInItem` (`'lgit'`). Read it in
  `applicationDidFinishLaunching`. In `applicationWillFinishLaunching`
  `currentAppleEvent` is nil.
- **Opening the window from outside a view works** through a published flag
  observed by the `MenuBarExtra` label view
  (`.onChange(of:initial: true)` → `openWindow(id:)`). The label is always
  alive, even with no window.
- **Reopen must be handled by the app.** With the `Window` suppressed, a Dock
  click on a windowless app does nothing unless the delegate sets that flag.

## Design

### Launch and the window

- Add an `NSApplicationDelegate` via `@NSApplicationDelegateAdaptor`. The app
  has none today.
- `Window("iSCSI Initiator", id: "main")` gets `.defaultLaunchBehavior(.suppressed)`.
- The delegate decides:
  - login launch → no window; start the auto-attach run.
  - any other launch → request the window (manual launches look the same as
    today).
  - `applicationShouldHandleReopen` with no visible windows → request the
    window.
- `AppModel` publishes the request (e.g. `wantsMainWindow`). The menu bar
  label observes it, calls `openWindow(id: "main")` and `NSApp.activate()`,
  then clears it.
- Only a login launch runs auto-attach. A manual launch, a Sparkle relaunch or
  a reopen never attaches anything the user did not click.
- **One launch at login.** While `SMAppService.mainApp.status == .enabled`, call
  `NSApp.disableRelaunchOnLogin()`. Otherwise call `enableRelaunchOnLogin()`.
  Re-apply both at every launch and after every register or unregister. This
  stops "Reopen windows when logging back in" from relaunching the app at login
  as a non-login launch, which would skip auto-attach. It also stops it from
  sending a reopen to the windowless login instance, which would open the
  window. *(My call.)*
- **Sparkle waits for the run.** On a login launch, `UpdateController` does not
  start the updater until the auto-attach run ends. An update alert is a window
  at login. While a run is in flight, `shouldPostponeRelaunchForUpdate` also
  postpones. A relaunch mid-run would kill the run, and the run's warnings
  would never show. *(My call.)*

### The auto-attach run

Owned by `AppModel`, which drives its own `refresh()`. Without a window,
nothing else refreshes: `MainWindow.task` and the `didBecomeActive` observer
never fire.

- Pending set = every target with `autoAttach == true` that is not already
  attached, read from the daemon. The first read is itself retried: the daemon
  or setup may not be ready a few seconds after login.
- Each attempt runs the whole path for each pending target:
  `setup.checkAll()` → `DaemonConnection.testConnection` →
  `attachments.attach`. It is the same sequence as `AppModel.attach`, without
  `lastError` alerts. Retrying the whole path is deliberate: late network, late
  daemon and late `fskit_agent` are all normal right after login.
- **Schedule:** attempts start 15 s apart, start to start, per target.
  Targets are attempted independently, so one slow target does not delay the
  others. A target never has two attempts in flight. An attempt that overruns
  (the TCP connect is 10 s; `mount -F` has no timeout and can hang under a
  wedged target) delays that target's next attempt instead of overlapping it.
  No attempt starts more than 5 min after the run began.
- **The 5 min end holds even if an attempt hangs.** At the deadline, a target
  whose attempt is still in flight counts as failed ("still attaching after
  5 min"). Its attempt is left running, not killed. If it later succeeds, the
  warning clears like any other attach. `AttachmentManager` gains no timeout,
  so manual attaches are unchanged. *(My call.)*
- **Silent:** no alerts, no window, no notification while the run is going.
  Rows still show the existing spinner during an actual attempt.
- A target leaves the pending set when:
  - it attaches. Attached but unformatted (device present, no volume) counts
    as attached: no retry, no alert. The row's existing "not formatted yet"
    subtitle says what is true.
  - the user acts on it: Attach, Detach, Remove, or saving it with the box
    unchecked. A manual Attach then runs the normal path, with its normal
    alerts. The run never re-mounts something the user just ejected.
- **End of run:**
  - every marked target attached → nothing visible happens.
  - otherwise, at the 5 min mark → request the window. Each target still
    failing carries its last error.
- All errors are retried, including authentication failures. The user asked
  for "keep trying". Classifying errors is not in scope.

### More than one user on the Mac

`autoAttach` lives in the daemon's machine-wide `targets.json`. The login item
(`SMAppService.mainApp`) and the mounts (each user's `fskit_agent`, under
`~/Library/Caches/me.herko.iSCSIInitiator/<tag>`) are per user. Under fast
user switching, a second user's login could therefore mount a volume the first
user has mounted. Two independent writers on one APFS volume corrupt it.
Decided by the user: handle it.

- **Before every attempt**, read the mount table (`getmntinfo`). A target is
  **in use elsewhere** when a mount's source (`f_mntfromname`,
  `scheme://portal/<iqn>/<lun>`) names its `targetIQN` and `lun`, and that
  mount's mount point (`f_mntonname`) is outside this user's home. Every
  attach starts with an FSKit mount in the home of the user who made it, so
  this user's own mounts never count as "elsewhere". The portal is not
  compared: one target reached through two addresses is still one target.
- In use elsewhere → skip that target for this attempt. Do not attach it, and
  record "in use by another session on this Mac" as its last error. It stays
  pending and is checked again on schedule, so it attaches if the other
  session ends within the 5 minutes. At the end of the run it is a failure like
  any other, with that text.
- Not the daemon's sessions, though this design first used them. A session
  belongs to whichever process opened it, and a process can outlive its use.
  Measured on the 26.6 VM, 2026-10-22: after a login-time extension launch
  failed, fskitd refused the next mount's activate ("previous task is
  running"). The extension kept the loaded resource and its daemon session
  with nothing mounted, so every later attempt read that session as another
  user's. The extension now gives such a load up (see Untested risks).
- Out of scope:
  - Two logins in the same instant both seeing no session. Fast user switching
    makes logins sequential.
  - Manual Attach, which stays a deliberate click and is unchanged.
  - Any daemon-side ownership guard.

### Failure state

- `AppModel` holds `autoAttachFailures: [targetID: PresentableError]`. It is
  set only at the end of the run, and cleared for a target when it attaches by
  any path or when the user removes it or unchecks the box.
- **Targets row:** orange `exclamationmark.triangle.fill` in place of the
  drive icon. The subtitle reads "Could not attach at login — <message>", with
  `.help()` giving the message plus the daemon's recovery suggestion. The
  Attach button stays.
- **Menu bar row:** orange dot in place of the grey one.
- **Menu bar icon:** `externaldrive.badge.exclamationmark` while any failure
  stands. It is already used for setup-incomplete; both mean "open me".
- **Landing section:** the existing rule is unchanged. Setup if `!isReady`,
  otherwise Targets.

### The checkbox and the login item

- `TargetEditor`: a toggle **Attach at login** writes `autoAttach`. Today
  `save()` copies the old value through.
- **Registration follows the user's saves.** After a successful save of a
  record that has the box checked, call `register()` if
  `SMAppService.mainApp.status != .enabled`. After a successful save or delete
  that leaves no target in the daemon's returned list marked, call
  `unregister()` if it is enabled. Editing an unrelated field on some other
  target registers nothing. There is no separate "Open at login" setting to
  disagree with.
- **Never re-register on launch.** If the user turned the item off in System
  Settings, that choice holds until they save a target with the box checked.
- **Location gate:** register only from `/Applications` and not translocated.
  This is the same check `InstallLocation` makes, so reuse it. Otherwise the
  toggle saves, the item is not registered, and the banner below says why.
- **Banner on Targets:** when any target is marked but
  `SMAppService.mainApp.status != .enabled`, say so. Include a button that
  registers (or, for `.requiresApproval`, calls
  `SMAppService.openSystemSettingsLoginItems()`). A checked box that silently
  does nothing is the failure to avoid.
- **Uninstaller:** add a step "Remove the login item" that calls
  `SMAppService.mainApp.unregister()`. It goes before "Remove the background
  service". It is independent of the daemon, but should run while the rest of
  the uninstall can still report.

### Testability

App code is not under `swift test`. Put the run's decision logic in a pure
type in `Sources/iSCSIKit/Support/`: pending set, start-to-start spacing,
deadline, user-cancel, and the end-of-run outcome. Give it an injected clock or
explicit instants. Test it in `Tests/iSCSIKitTests` with **no real waits**: the
CI timing fragility in `CLAUDE.md` applies. The app wires it to
`Task.sleep`, `DaemonConnection` and `AttachmentManager`.

## Non-goals

- Attaching before login, at boot, or from the daemon.
- Re-attaching later in the session: after sleep, after a network change, or
  after the user ejects.
- Detaching at logout. Whatever happens to FSKit mounts at logout today still
  happens.
- Notifications (`UNUserNotificationCenter`). The window is the signal.
- An "open at login without attaching anything" setting.

## Anti-goals

- A window or alert at login when everything attached.
- Re-mounting a volume the user ejected.
- Overriding the user's Login Items choice in System Settings.
- Any change to `TargetRecord`'s keys.

## Housekeeping

- After adding files to the app target, run `SWIFT_DETERMINISTIC_HASHING=1
  xcodegen generate` and commit the `.pbxproj`.
- `docs/open-questions.md` §7, "Root daemon reading the keychain before
  login": record that auto-attach was built post-login and in the app, so the
  item stays moot.
- README feature list: one line.

## Verification

- Unit: the schedule type, as above.
- 192.168.64.16 (SIP on), notarized build: mark one reachable and one
  unreachable target. Reboot. The reachable one mounts with no window. The
  window opens at about 5 min with a warning on the other. Then unblock the
  unreachable target partway through a second run and confirm it attaches with
  no window. To make a target unreachable, block its address with `pfctl` on
  the VM, or give it a bogus portal.
- Manual launch and Dock click on a windowless app both show the window.
- Uncheck the last marked target: the login item is gone from System Settings.
  Uninstall: the same.
- Two accounts on the VM. Account A has a marked target attached. Fast-switch
  to account B, which has its login item registered. B does not mount it. At
  5 min B's window shows "in use by another session". Eject in A while B's run
  is still going: B attaches it.

- **Logout and login with the app running, "Reopen windows" checked, the box
  on.** A plain `reboot` on an auto-login VM does not exercise window
  restoration. Expect exactly one launch, carrying `'lgit'`, and no window.
- **Menu bar item hidden** (macOS 26 Menu Bar settings): manual launch, Dock
  reopen and the end-of-run window must still open the window.

## Untested risks

- **Window restoration** is handled by `disableRelaunchOnLogin` above, but that
  is not yet verified. See Verification.
- **A hidden menu bar item.** The only path to `openWindow` is the
  `MenuBarExtra` label, and the spike ran with the item visible. If the label
  stops observing changes while hidden, the fallback is a URL scheme handled by
  the `Window` scene (`handlesExternalEvents(matching:)`), opened with
  `NSWorkspace.open`. Build the label path first and fall back only if the VM
  check fails. *(My call.)* **It failed** on the 26.6 VM, 2026-10-22. With
  the item hidden, a manual launch and a Dock click both opened the window,
  because the app is active then. A run that ended in the background set the
  flag, and nothing opened until a Dock click made the app active. The end of
  a run now also opens the window by URL. The URL is pinned to this copy of
  the app, and it shows the window and does nothing else. A MacBook with a
  notch and a full menu bar hides the item without any setting.
- **App Nap.** The same day, a run whose attempts made no XPC calls went
  silent 3 s after RunningBoard enabled App Nap for the windowless app. Its
  15 s sleeps stretched to minutes, and so did the 5 min deadline. The run now
  holds a user-initiated activity (`ProcessInfo.beginActivity`) from start to
  end. *(My call.)*
- **A load that is never activated.** At the login measured above, macOS's
  first extension launch failed. fskitd then refused the next activate, and
  the extension kept the loaded resource with nothing mounted. While it did,
  fskitd refused every new mount of that resource ("resource state is 4").
  FSKit never sends `unloadResource`, so the extension now exits when no
  `activate` follows a successful load within 30 s. Every measured load was
  activated within 6 ms. Unverified: whether that exit returns the resource
  to a mountable state. It could not be reproduced from outside the login
  session. *(My call.)*

## Left to the builder

Names, file placement inside the app, the exact copy text, and how the pure
schedule type exposes time.
