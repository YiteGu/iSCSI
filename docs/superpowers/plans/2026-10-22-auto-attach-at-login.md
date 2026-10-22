# Attach at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Targets marked "Attach at login" attach after the user logs in, with no window. A target that still fails after 5 minutes of silent retries gets a warning in a window that opens by itself.

**Architecture:**
- **Pure decision logic lives in iSCSIKit, so `swift test` covers it.** That means the retry schedule, the pending set, the multi-user "in use elsewhere" rule and the login-item register/unregister rule.
- **The app owns everything with side effects.**
  - An `NSApplicationDelegate` recognises a login launch by the `oapp` event's `'lgit'` prop data.
  - A suppressed `Window` is opened through a flag that the `MenuBarExtra` label observes.
  - `AutoAttacher` drives one retry loop per target against `AppModel`.
  - `SMAppService.mainApp` is the login item.

**Tech Stack:** Swift 6, SwiftUI, AppKit, ServiceManagement, Sparkle, swift-testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-22-auto-attach-at-login-design.md`

## Global Constraints

- Every target is Swift 6 language mode. Tests are swift-testing (`@Test` / `#expect`), not XCTest. Before calling anything done, run the whole suite with `swift test --no-parallel`.
- **Tests never wait on real time.** The schedule type takes explicit `Duration` offsets. This follows the CI timing fragility documented in `CLAUDE.md`.
- `TargetRecord` gets **no new keys**. Use the existing `autoAttach: Bool`.
- No new plist. The login item is `SMAppService.mainApp`.
- Attach stays in the app, never the daemon.
- `Sources/iSCSIKit` stays side-effect-free. The new files there import only Foundation.
- The app builds against the **macOS 26 SDK**. The dev host has Xcode 27, which accepts code Xcode 26 rejects. Task 7 builds on the 26.6 VM, and that build is the authority.
- After adding app source files, run `cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate` and commit the regenerated `.pbxproj`. Never hand-edit it.
- `xcodebuild` rewrites `Package.resolved`'s `originHash`. Restore it with `git checkout -- Package.resolved` and never commit it.
- App compile check on the dev host, used by every app task:
  `cd apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"; cd .. && git checkout -- Package.resolved`
  Expected: `** BUILD SUCCEEDED **` and no `error:` lines.
- App log lines use `Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "autoattach")`. Read them with `/usr/bin/log`, never bare `log`.
- Nothing is installed or registered on the dev host.
- Work on branch `auto-attach-at-login`. Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01McFrMEugnMm7XX1MF25b3X
  ```

## Review Focus

1. **A `mount -F` that hangs at the 5 min mark** must not hold up the end of the run. The target is reported as still attaching. Tested in Task 1 by `deadlineHoldsWithAttemptInFlight`.
2. **An attempt that runs past 15 s** must not overlap the next one. The next starts as soon as it ends. Tested in Task 1 by `overrunDelaysInsteadOfOverlapping`.
3. **Editing an unrelated target** must not re-register a login item the user turned off in System Settings. Tested in Task 2 by `unrelatedSaveNeverRegisters`.
4. **This user's own attached volume** must never count as "in use elsewhere". Otherwise a second run in the same session would warn about the user's own disk. Tested in Task 1 by `ownAttachmentIsNotElsewhere`.
5. **A late result for a cancelled target**: the user pressed Detach mid-run and the in-flight attempt then reports. It must not bring the target back as pending or as a failure. Tested in Task 1 by `cancelledTargetStaysCancelled`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/iSCSIKit/Support/AutoAttachRun.swift` (create) | Pure per-target retry state, schedule, end-of-run failures, pending set, in-use-elsewhere rule |
| `Sources/iSCSIKit/Support/LoginItemPolicy.swift` (create) | Pure register/unregister decision after a save or delete |
| `Tests/iSCSIKitTests/AutoAttachRunTests.swift`, `Tests/iSCSIKitTests/LoginItemPolicyTests.swift` (create) | Their tests |
| `apps/iSCSIApp/AppDelegate.swift` (create) | Owns `AppModel`, detects a login launch, handles reopen |
| `apps/iSCSIApp/Menu/MenuBarLabel.swift` (create) | Menu bar symbol, and the only place `openWindow(id: "main")` runs from outside a window |
| `apps/iSCSIApp/Client/LoginItem.swift` (create) | `SMAppService.mainApp` status, register/unregister, relaunch-on-login policy, location gate |
| `apps/iSCSIApp/Client/AutoAttacher.swift` (create) | The login-time run that drives `AutoAttachRun` against `AppModel` |
| `apps/iSCSIApp/iSCSIApp.swift` (modify) | Delegate adaptor, suppressed `Window`, `MenuBarLabel` |
| `apps/iSCSIApp/Client/AppModel.swift` (modify) | Window flag, failures, quiet refresh, shared attach body, cancel hooks, login-item sync |
| `apps/iSCSIApp/Client/UpdateController.swift` (modify) | Updater starts on demand, not in `init` |
| `apps/iSCSIApp/Windows/TargetsView.swift` (modify) | Toggle, failure row state, login-item banner |
| `apps/iSCSIApp/Menu/MenuBarContent.swift` (modify) | Orange dot for a failed row |
| `apps/iSCSIApp/Setup/Uninstaller.swift` (modify) | "Remove the login item" step |
| `docs/open-questions.md`, `README.md` (modify) | §7 note; feature line |

---

### Task 1: `AutoAttachRun`, the pure retry state

**Files:**
- Create: `Sources/iSCSIKit/Support/AutoAttachRun.swift`
- Test: `Tests/iSCSIKitTests/AutoAttachRunTests.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`, `Equatable`). Every `Duration` here is an offset from the run's start:
  ```swift
  public struct AutoAttachRun {
      public static let interval: Duration = .seconds(15)
      public static let budget: Duration = .seconds(300)
      public enum Failure: Sendable, Equatable { case lastAttemptFailed, stillAttaching }
      public init(targetIDs: [String], interval: Duration = Self.interval, budget: Duration = Self.budget)
      public func canStart(_ id: String, at now: Duration) -> Bool
      public mutating func started(_ id: String, at now: Duration)
      public mutating func finished(_ id: String, attached: Bool)
      public mutating func cancel(_ id: String)
      public func nextStart(for id: String) -> Duration?
      public func isOver(at now: Duration) -> Bool
      public var failures: [String: Failure] { get }
      public static func pendingTargetIDs(_ targets: [TargetRecord], attachedTargetIDs: Set<String>) -> [String]
      public static func isInUseElsewhere(_ target: TargetRecord, sessions: [SessionInfo], attachedTargetIDs: Set<String>) -> Bool
  }
  ```

Semantics, which the tests pin:
- Each target is waiting (with an optional last start), attempting (since a start), attached, or cancelled.
- `canStart` is true only when all of these hold: the target is waiting, `now < budget`, and either it has never started or `now >= lastStart + interval`.
- `finished(attached: false)` returns the target to waiting, keeping its start time as last start. `finished` on a cancelled or unknown id is ignored.
- `nextStart` is `lastStart + interval` (or `.zero` if never started) while waiting. It is `nil` if that time is at or past the budget, and `nil` in every other state.
- `isOver` is true once `now >= budget`, or once every target is attached or cancelled.
- `failures` maps each target still waiting to `.lastAttemptFailed` and each target still attempting to `.stillAttaching`. Attached and cancelled targets are absent.
- `pendingTargetIDs` keeps targets with `autoAttach` that are not in `attachedTargetIDs`, in input order.
- `isInUseElsewhere` is true when some session has the same `targetIQN` and `lun` and `attachedTargetIDs` does not contain the target's `id`.

- [ ] **Step 1: Write the failing tests** in `@Suite("Auto-attach run") struct AutoAttachRunTests`. Use a helper `func record(_ id: String, autoAttach: Bool = true, lun: UInt64 = 0) -> TargetRecord` (host `192.168.20.1`, IQN `iqn.2026-08.me.herko:disk0`) and `func session(lun: UInt64 = 0) -> SessionInfo` (`handle: "h"`, same IQN, `writeThrough: true, recoveryCount: 0, negotiated: [:]`).

| Test | Arrange | Expect |
|---|---|---|
| `everyTargetStartsAtOnce` | `["a","b"]` | `canStart("a", at: .zero)`, `canStart("b", at: .zero)` |
| `attemptsAreFifteenSecondsApart` | start a@0, `finished(a, attached: false)` | `nextStart(for: "a") == .seconds(15)`; `!canStart("a", at: .seconds(14))`; `canStart("a", at: .seconds(15))` |
| `overrunDelaysInsteadOfOverlapping` | start a@0 | `!canStart("a", at: .seconds(20))`; then `finished(a, attached: false)`, and `canStart("a", at: .seconds(20))` |
| `noAttemptStartsAtTheBudget` | start a@285, finish false | `nextStart(for: "a") == nil`; `!canStart("a", at: .seconds(300))` |
| `deadlineHoldsWithAttemptInFlight` | start a@290 | `!isOver(at: .seconds(299))`; `isOver(at: .seconds(300))`; `failures == ["a": .stillAttaching]` |
| `failedTargetReportsLastAttempt` | start a@0, finish false | `isOver(at: .seconds(300))`; `failures == ["a": .lastAttemptFailed]` |
| `attachedTargetIsDone` | `["a"]`, start a@0, finish true | `nextStart(for: "a") == nil`; `isOver(at: .seconds(1))`; `failures.isEmpty` |
| `runEndsEarlyOnlyWhenAllResolved` | `["a","b"]`; a: start@0, finish true; b: start@0, finish false | `!isOver(at: .seconds(20))`; then `cancel("b")` and `isOver(at: .seconds(20))`, `failures.isEmpty` |
| `cancelledTargetStaysCancelled` | start a@0, `cancel("a")`, then `finished("a", attached: false)` | `nextStart(for: "a") == nil`; `!canStart("a", at: .seconds(60))`; `failures.isEmpty` |
| `emptyRunIsOverImmediately` | `[]` | `isOver(at: .zero)` |
| `onlyMarkedUnattachedTargetsArePending` | records t1 (marked), t2 (marked), t3 (`autoAttach: false`); attached `["t2"]` | `pendingTargetIDs(...) == ["t1"]` |
| `sessionElsewhereCountsAsInUse` | record t1, `[session()]`, attached `[]` | `isInUseElsewhere == true` |
| `ownAttachmentIsNotElsewhere` | record t1, `[session()]`, attached `["t1"]` | `false` |
| `otherLUNDoesNotCount` | record t1 (lun 0), `[session(lun: 1)]`, attached `[]` | `false` |

- [ ] **Step 2: Run them and see them fail**
  Run: `swift test --filter AutoAttachRun`
  Expected: compile failure, `cannot find 'AutoAttachRun' in scope`.

- [ ] **Step 3: Implement `AutoAttachRun`** in `Sources/iSCSIKit/Support/AutoAttachRun.swift`. Use one private `enum State` per target, stored in a `[String: State]`. Keep the input order in a separate `[String]` for stable iteration. Add a header comment that says why it exists: login-time attach retried silently, decided purely so tests need no clock. Point to the spec.

- [ ] **Step 4: Run them and see them pass**
  Run: `swift test --filter AutoAttachRun`
  Expected: all 14 pass.

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/iSCSIKit/Support/AutoAttachRun.swift Tests/iSCSIKitTests/AutoAttachRunTests.swift
  git commit -m "Add the pure schedule for attaching at login"   # plus the trailer
  ```

---

### Task 2: `LoginItemPolicy`

**Files:**
- Create: `Sources/iSCSIKit/Support/LoginItemPolicy.swift`
- Test: `Tests/iSCSIKitTests/LoginItemPolicyTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum LoginItemPolicy {
      public enum Action: Sendable, Equatable { case register, unregister, blockedByLocation, none }
      /// savedIsMarked: the record just saved has the box checked; nil for a delete.
      /// anyMarked: any target in the daemon's list after the change has autoAttach.
      /// isRegistered: SMAppService.mainApp.status is .enabled or .requiresApproval.
      /// isEnabled: status is .enabled. canRegisterFromHere: in /Applications, not translocated.
      public static func action(savedIsMarked: Bool?, anyMarked: Bool, isRegistered: Bool,
                                isEnabled: Bool, canRegisterFromHere: Bool) -> Action
  }
  ```

Rules, in this order:
1. No target is marked and the item is registered → `.unregister`.
2. The saved record is marked and the item is not enabled: `.register` if `canRegisterFromHere`, otherwise `.blockedByLocation`.
3. Anything else → `.none`.

- [ ] **Step 1: Write the failing tests** in `@Suite("Login item policy")`:
  - `savingAMarkedTargetRegisters`: `(true, true, false, false, true)` → `.register`
  - `unrelatedSaveNeverRegisters`: `(false, true, true, false, true)` → `.none`. This is the user-turned-it-off case: registered, not enabled, an unmarked record saved.
  - `markedSaveWhileEnabledDoesNothing`: `(true, true, true, true, true)` → `.none`
  - `lastUnmarkUnregisters`: `(false, false, true, true, true)` → `.unregister`
  - `deleteOfLastMarkedUnregisters`: `(nil, false, true, true, true)` → `.unregister`
  - `nothingMarkedNothingRegisteredDoesNothing`: `(false, false, false, false, true)` → `.none`
  - `outsideApplicationsIsBlocked`: `(true, true, false, false, false)` → `.blockedByLocation`

- [ ] **Step 2: Run them and see them fail**
  Run: `swift test --filter LoginItemPolicy`
  Expected: `cannot find 'LoginItemPolicy' in scope`.

- [ ] **Step 3: Implement `LoginItemPolicy.action`** using the three rules above.

- [ ] **Step 4: Run them and see them pass**
  Run: `swift test --filter LoginItemPolicy`
  Expected: 7 pass.

- [ ] **Step 5: Commit** both files with "Decide when the app registers itself as a login item".

---

### Task 3: Launch plumbing — delegate, suppressed window, deferred Sparkle

**Files:**
- Create: `apps/iSCSIApp/AppDelegate.swift`, `apps/iSCSIApp/Menu/MenuBarLabel.swift`, `apps/iSCSIApp/Client/LoginItem.swift`
- Modify: `apps/iSCSIApp/iSCSIApp.swift`, `apps/iSCSIApp/Client/AppModel.swift`, `apps/iSCSIApp/Client/UpdateController.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject`, with:
    - `let model = AppModel()`
    - `func applicationDidFinishLaunching(_:)`
    - `func applicationShouldHandleReopen(_:hasVisibleWindows:) -> Bool`
    - `static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool`
  - `AppModel`, new members:
    - `@Published var wantsMainWindow = false`
    - `func beginLoginLaunch()`. In this task it only calls `updates.start()`. Task 4 replaces the body.
  - `UpdateController.start()`: starts Sparkle once. Repeat calls do nothing.
  - `@MainActor enum LoginItem`, with:
    - `static var status: SMAppService.Status`
    - `static func applyRelaunchPolicy()`

- [ ] **Step 1: `UpdateController`.** Construct with `startingUpdater: false`. Add `func start()`, guarded by a private `didStart` flag, that calls `controller.startUpdater()`. In the file's header comment, say why the start is deferred: a login launch must not show an update alert while the silent run is going, and before `start()` no check can find an update, so the postpone path needs no change.

- [ ] **Step 2: `LoginItem`.**
  - `status` returns `SMAppService.mainApp.status`.
  - `applyRelaunchPolicy()` calls `NSApp.disableRelaunchOnLogin()` when `status == .enabled` and `NSApp.enableRelaunchOnLogin()` otherwise.
  - The comment says why: with the login item on, macOS's "Reopen windows" relaunch would either be a second launch that skips auto-attach, or a reopen that opens the window (spec, "One launch at login").

- [ ] **Step 3: `AppDelegate`.**
  - `isLoginItemLaunch` returns true when `event?.eventID == kAEOpenApplication` and `event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem`. Use `OSType` literals (`0x6F617070` `'oapp'`, `0x70726474` `'prdt'`, `0x6C676974` `'lgit'`) if the Carbon constants are not visible.
  - `applicationDidFinishLaunching`:
    - call `LoginItem.applyRelaunchPolicy()`;
    - read `NSAppleEventManager.shared().currentAppleEvent`, which is nil in `willFinish`, per the spike;
    - on a login launch, call `model.beginLoginLaunch()`;
    - otherwise set `model.wantsMainWindow = true` and call `model.updates.start()`;
    - log which kind of launch it was.
  - `applicationShouldHandleReopen`: if `!hasVisibleWindows`, set `model.wantsMainWindow = true`. Return `false`.
  - Header comment: record the spike table from the spec in one line per row.

- [ ] **Step 4: `MenuBarLabel`.**
  - `struct MenuBarLabel: View` holds `@ObservedObject var model: AppModel` and `@Environment(\.openWindow) private var openWindow`.
  - The body is `Image(systemName: symbol)`, where `symbol` is the current `menuBarSymbol` logic moved from `iSCSIApp.swift` unchanged.
  - Add `.onChange(of: model.wantsMainWindow, initial: true) { _, wants in ... }`. When `wants` is true: set `model.wantsMainWindow = false`, call `openWindow(id: "main")`, then `NSApp.activate()`.
  - Comment: this is the only always-alive view, which is why the request lives here.

- [ ] **Step 5: `ISCSIInitiatorApp`.**
  - Replace `@StateObject private var model = AppModel()` with `@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate` plus `private var model: AppModel { appDelegate.model }`.
  - Add `.defaultLaunchBehavior(.suppressed)` to the `Window` scene.
  - Change the `MenuBarExtra` label to `MenuBarLabel(model: model)`.
  - Delete `menuBarSymbol`.
  - Update the header comment: the window no longer opens by itself; the delegate decides.

- [ ] **Step 6: Regenerate the project and compile**
  Run: `cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && cd ..`, then the app compile check from Global Constraints.
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit** the three new files, the three modified ones and the `.pbxproj` with "Open the window only on request, and tell a login launch apart".

---

### Task 4: The login-time run, and how a failure looks

**Files:**
- Create: `apps/iSCSIApp/Client/AutoAttacher.swift`
- Modify: `apps/iSCSIApp/Client/AppModel.swift`, `apps/iSCSIApp/Windows/TargetsView.swift` (`TargetRow`), `apps/iSCSIApp/Menu/MenuBarContent.swift` (`MenuRow`), `apps/iSCSIApp/Menu/MenuBarLabel.swift`

**Interfaces:**
- Consumes:
  - `AutoAttachRun` (Task 1);
  - from Task 3: `AppModel.beginLoginLaunch()`, `wantsMainWindow` and `updates.start()`.
- Produces: `AppModel`, new or changed members:
  - `@Published private(set) var autoAttachFailures: [String: PresentableError] = [:]`
  - `@discardableResult func refresh(reportingErrors: Bool = true) async -> Bool` returns true when the target list was read. After `reconcile`, it drops failures for targets that are now attached.
  - `func performAttach(_ target: TargetRecord) async throws -> Attachment` is the body of today's `attach`: `testConnection` → `attachments.attach` → refresh `sessions`. It shows no alerts and does not touch `busy`.
  - `func withBusy<T>(_ id: String, _ work: () async throws -> T) async rethrows -> T`
  - `func recordAutoAttachFailures(_ failures: [String: PresentableError])` and `func clearAutoAttachFailure(for id: String)`
  - `lazy var autoAttacher = AutoAttacher(model: self)`
  - `Row.autoAttachFailure: PresentableError?`
- Produces:
  - `@MainActor final class AutoAttacher`, with `init(model: AppModel)`, `var isRunning: Bool { get }`, `func start(onFinish: @escaping @MainActor () -> Void)` and `func cancel(targetID: String)`.
  - The fixed copy, as `static let` strings on `AutoAttacher`:

| Case | `message` | `suggestion` |
|---|---|---|
| in use elsewhere | `In use by another session on this Mac.` | `Attaching it from two accounts at once would corrupt it. Eject it in the other account, then attach it here.` |
| still attaching | `Still trying to attach after 5 minutes.` | `It will appear by itself if the target answers. Otherwise check the target and press Attach.` |
| setup not ready | `Setup is not finished.` | `Open the Setup screen to see what is missing.` |

  - Every failure's `title` is `Could not attach “<displayName>” at login`. For an attempt that threw, `message` and `suggestion` come from the error, exactly as `AppModel.present` builds them.

- [ ] **Step 1: Refactor `AppModel.attach`.**
  - `attach` now:
    1. calls `autoAttacher.cancel(targetID:)`;
    2. wraps `performAttach` in `withBusy`;
    3. on success, calls `clearAutoAttachFailure`, then keeps today's not-formatted notice;
    4. on failure, keeps today's `present`.
  - `detach`, `delete`, and `save` of a record with `autoAttach == false` call `autoAttacher.cancel(targetID:)` and `clearAutoAttachFailure(for:)` first.
  - `refresh` gets `reportingErrors` and the Bool result. Existing callers compile unchanged.

- [ ] **Step 2: `AutoAttacher.start`.** Implement this algorithm (it is not determined by the signatures):
  ```
  start: guard !isRunning; isRunning = true; t0 = ContinuousClock.now; log "run started"
  phase 1, the target list:
      loop: if await model.refresh(reportingErrors: false) && model.isReady → break
            if elapsed >= AutoAttachRun.budget → conclude(); return     // window lands on Setup
            sleep AutoAttachRun.interval
  run = AutoAttachRun(targetIDs: pendingTargetIDs(model.targets, attached: ids in model.attachments.attachments))
  if run.isOver(at: elapsed) → conclude(); return
  one Task per pending id (kept in a [String: Task] so cancel can stop the loop between attempts):
      while run.canStart(id, at: elapsed):
          run.started(id, at: elapsed)
          error = await attemptOnce(id)            // nil means attached
          run.finished(id, attached: error == nil)
          if error == nil { model.clearAutoAttachFailure(for: id) }
          else { lastErrors[id] = error; if concluded, replace that target's warning with it }
          if run.isOver(at: elapsed) → conclude()
          guard let next = run.nextStart(for: id) else break
          sleep until t0 + next                     // returns at once if already past
  one budget Task: sleep until t0 + budget, then conclude()
  conclude (runs once): failures = run.failures mapped to PresentableError
      (.stillAttaching → the fixed copy; .lastAttemptFailed → lastErrors[id]);
      model.recordAutoAttachFailures(failures);
      if !failures.isEmpty || phase 1 never finished → model.wantsMainWindow = true;
      isRunning = false; log the outcome; onFinish()
  ```
  - `attemptOnce(id)`:
    1. If `!model.isReady`, run `await model.setup.checkAll()` once. If setup is still not ready, return the setup-not-ready failure.
    2. Read `DaemonConnection.sessions()`. If `AutoAttachRun.isInUseElsewhere(target, sessions:, attachedTargetIDs:)`, return the in-use failure.
    3. Otherwise run `try await model.withBusy(id) { try await model.performAttach(target) }`. Return nil on success, the presented error on throw.
    4. Look up the target fresh from `model.targets` each time. If the record is gone, call `run.cancel(id)` and stop.
  - `cancel(targetID:)` calls `run.cancel` and cancels that target's sleeping loop task. An attempt already in flight finishes, and the run ignores its result.
  - Log each attempt and its result at `.info`.

- [ ] **Step 3: Wire the login launch.** Replace the Task 3 body of `beginLoginLaunch()` with `autoAttacher.start { [weak self] in self?.updates.start() }`.

- [ ] **Step 4: Failure on screen.**
  - `rows` fills `autoAttachFailure` from `autoAttachFailures[target.id]`.
  - `TargetRow`, when the row is not attached and `autoAttachFailure` is set:
    - icon `exclamationmark.triangle.fill` in `.orange` instead of the drive;
    - subtitle `Could not attach at login — <message>`;
    - `.help(message + "\n\n" + suggestion)`;
    - the Attach button stays.
  - `MenuRow`: the dot is `.orange` when `row.autoAttachFailure != nil` and the row is not attached.
  - `MenuBarLabel.symbol`: use `externaldrive.badge.exclamationmark` when `!model.isReady || !model.autoAttachFailures.isEmpty`.

- [ ] **Step 5: Regenerate and compile**, the same as Task 3 Step 6.
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit** with "Attach marked targets at login, retrying silently for five minutes".

---

### Task 5: The checkbox and the login item

**Files:**
- Modify: `apps/iSCSIApp/Client/LoginItem.swift`, `apps/iSCSIApp/Client/AppModel.swift`, `apps/iSCSIApp/Windows/TargetsView.swift` (`TargetEditor`, `TargetsView`)

**Interfaces:**
- Consumes: `LoginItemPolicy.action` (Task 2), and `LoginItem.status` and `applyRelaunchPolicy()` (Task 3).
- Produces:
  - `LoginItem`, new members:
    - `static var canRegisterFromHere: Bool`, which uses `InstallLocation().isInApplications && !InstallLocation().isTranslocated`;
    - `static func register() throws` and `static func unregister() async throws`. Each calls `applyRelaunchPolicy()` after.
  - `AppModel`, new members:
    - `@Published private(set) var loginItemStatus: SMAppService.Status`, refreshed in `refresh()` and after every sync;
    - `private func syncLoginItem(savedIsMarked: Bool?)`, called after a successful `save` (with `stored.autoAttach`) and after a successful `delete` (with `nil`);
    - `func turnOnLoginItem()`, which the banner calls.

- [ ] **Step 1: `TargetEditor`.**
  - Add `@State private var autoAttach: Bool`, initialised from `target?.autoAttach ?? false`.
  - `save()` passes `autoAttach: autoAttach` instead of copying `existing?.autoAttach`.
  - Add a section after "Network": `Section { Toggle("Attach at login", isOn: $autoAttach) } footer: { Text("Attaches by itself when you log in to this Mac. If the target can't be reached, keeps trying for 5 minutes, then shows a warning here.").font(.caption).foregroundStyle(.secondary) }`.

- [ ] **Step 2: `syncLoginItem`.**
  - Compute the action:
    - `anyMarked` = `targets.contains(where: \.autoAttach)`;
    - `isRegistered` = status is `.enabled` or `.requiresApproval`;
    - `isEnabled` = status is `.enabled`.
  - Then act on it:
    - `.register` → `try LoginItem.register()`;
    - `.unregister` → `try await LoginItem.unregister()`;
    - `.blockedByLocation` and `.none` → nothing.
  - On any error, `present(error, doing: "Changing the login item")`.
  - Finally update `loginItemStatus`.

- [ ] **Step 3: Banner on `TargetsView`.**
  - Show it above the list when `model.targets.contains(where: \.autoAttach) && model.loginItemStatus != .enabled`.
  - It is one line of text and one button:

| Condition | Text | Button → action |
|---|---|---|
| `!LoginItem.canRegisterFromHere` | `Attach at login needs the app in /Applications.` | `Show in Finder` → `InstallLocation().perform()` |
| `.requiresApproval` | `Attach at login is turned off in System Settings.` | `Open Login Items…` → `SMAppService.openSystemSettingsLoginItems()` |
| otherwise | `iSCSI Initiator is not set to open at login, so nothing will attach.` | `Turn On` → `model.turnOnLoginItem()` |

  - Style it like the menu's setup banner: `exclamationmark.circle.fill` in orange, not an error style.

- [ ] **Step 4: Compile**, the same as Task 3 Step 6, without the regenerate, since no new files were added.
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** with "Add the Attach at login checkbox and keep the login item in step with it".

---

### Task 6: Uninstall removes the login item

**Files:**
- Modify: `apps/iSCSIApp/Setup/Uninstaller.swift`

**Interfaces:**
- Consumes: `LoginItem.status` and `LoginItem.unregister()` (Tasks 3 and 5).

- [ ] **Step 1: Add the step.**
  - Insert `Step(label: "Remove the login item", outcome: .pending)` at index 2, before "Remove the background service", and renumber the `step(n)` calls.
  - Add `private func unregisterLoginItem() async throws -> String`:
    - status already `.notRegistered` or `.notFound` → return `"was not set"`;
    - otherwise `try await LoginItem.unregister()`;
    - if status is still neither, throw `UninstallError.loginItemStillRegistered(status)`;
    - otherwise return `"removed"`.
  - Add that case to `UninstallError`, with a recovery suggestion that names System Settings → General → Login Items.
  - Add the step to the numbered list in the header comment.

- [ ] **Step 2: Compile**, the same check.
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit** with "Remove the login item on uninstall".

---

### Task 7: Docs, full suite, and the macOS 26 SDK build

**Files:**
- Modify: `docs/open-questions.md` (§7, the "Root daemon reading the keychain before login" bullet), `README.md` (the feature list near line 116)

- [ ] **Step 1: Docs.**
  - Append to the §7 bullet: auto-attach at login was built (2026-10-22) in the app, after login, through the user's `fskit_agent`, so the daemon still never needs secrets before login and this item stays moot. Link the spec.
  - README: add `- **Attach at login**, per target, retrying for five minutes when the storage is not reachable yet.` after the "Discover, add, attach, detach" line.

- [ ] **Step 2: Full suite.**
  Run: `swift test --no-parallel > "${TMPDIR:-/tmp}/auto-attach-test.log" 2>&1; echo "exit=$?"; grep -E "Test run with|✘" "${TMPDIR:-/tmp}/auto-attach-test.log"`
  Expected: `exit=0`, no `✘`.

- [ ] **Step 3: `.pbxproj` in sync.**
  Run: `cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && cd .. && git diff --exit-code apps/iSCSIInitiator.xcodeproj && echo "pbxproj in sync"`
  Expected: `pbxproj in sync`.

- [ ] **Step 4: Build against the macOS 26 SDK on the 26.6 VM.** This compiles only and installs nothing. Keep the tree in its own directory, not `~/iSCSI`.
  ```bash
  rsync -a --delete --exclude .build --exclude apps/build --exclude .git ./ herko@192.168.64.16:src/auto-attach/
  ssh herko@192.168.64.16 'cd ~/src/auto-attach/apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme "iSCSI Initiator" -configuration Release -destination "generic/platform=macOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"'
  ```
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** the docs with "Document attach at login".

---

### Task 8: Acceptance on the SIP-on VM (192.168.64.16)

Needs a notarized build. **Pushing the branch and running the release workflow are outward-facing: ask the user before either.** Make the RC with `gh workflow run release.yml -f publish=false --ref auto-attach-at-login`, never a tag. The DMG is the run's `dmg` artifact.

Install it over the existing app with the in-place recipe in `docs/backend-a-fskit-notes.md`. Ask the user for any GUI step at the UTM console.

**VM rules:**
- `ssd-vms` is live VM storage: never mark it, attach it or modify it.
- `name-testing` is the only scratch namespace.
- For an unreachable target, add a record at `192.0.2.1` (TEST-NET-1).

**Logs:** follow progress with
`ssh herko@192.168.64.16 '/usr/bin/log show --last 10m --info --debug --predicate "subsystem == \"me.herko.iSCSIInitiator.app\" AND category == \"autoattach\""'`

- [ ] **Step 1: Happy path.** Mark `name-testing`, confirm it shows up in System Settings → Login Items, then `sudo -n shutdown -r now`.
  Expected: after auto-login, `name-testing` mounts, no window opens, and the log shows a login launch and the run finishing with no failures.
- [ ] **Step 2: Failure path.** Also mark the `192.0.2.1` record, then reboot.
  Expected:
  - `name-testing` mounts;
  - about 20 attempts are logged for the bogus record;
  - at about 5 min the window opens on Targets, with the orange warning and the error;
  - the menu bar icon has the exclamation badge.
- [ ] **Step 3: Late recovery.** Block the NAS with `sudo -n pfctl` for 60 s after login, then unblock.
  Expected: `name-testing` attaches within 15 s of the unblock, and no window opens.
- [ ] **Step 4: Manual launch, Dock reopen, and a hidden menu bar item.**
  Expected:
  - a manual `open` shows the window and attaches nothing;
  - closing the window and clicking the Dock icon reopens it;
  - with the item hidden in Menu Bar settings, both still work.
  - If the hidden-item case fails, stop and implement the spec's URL-scheme fallback as a new task.
- [ ] **Step 5: Window restoration.** With the app running and "Reopen windows" checked, log out and log in at the console. The user does this.
  Expected: exactly one launch, logged as a login launch, and no window.
- [ ] **Step 6: Unregister paths.**
  Expected: unchecking the last marked target removes the item from Login Items, and so does running Remove iSCSI Initiator…. Reinstall afterwards to restore the rig.
- [ ] **Step 7: Two accounts.** This needs a second user on the VM; **ask before creating one.** Then run the spec's two-account check.
  Expected:
  - with account A attached, B gets the "in use by another session" warning;
  - if A ejects during B's run, B attaches.
- [ ] **Step 8: Record the results** in `docs/test-playbook.md` under a dated heading, then commit.
