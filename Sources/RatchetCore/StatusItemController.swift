// SPDX-License-Identifier: GPL-3.0-or-later
// Sources/RatchetCore/StatusItemController.swift
import AppKit

@MainActor
public final class StatusItemController {
    public typealias LoginHandler = () async throws -> Void

    /// The actual `SMAppService.mainApp.register()`/`.unregister()` call. Injected rather than
    /// called directly here because `ServiceManagement` is a system side effect on par with
    /// `performLogin` above — `RatchetCore` stays a place that only
    /// describes what should happen, and the executable target (which already owns the other
    /// real-world calls) supplies how.
    ///
    /// Returns the state actually achieved rather than `Void`: `register()` can return
    /// successfully while the login item sits in `.requiresApproval` (common on first
    /// registration, until the user approves it in System Settings) — not an error, but also
    /// not "enabled" yet. The caller uses the returned value, not the requested one, to decide
    /// what the checkbox should show.
    public typealias SetLaunchAtLoginHandler = (Bool) async throws -> Bool

    private let statusItem: NSStatusItem
    private let appState: AppState
    private let dataStore: DataStore
    private let performLogin: LoginHandler
    private let setLaunchAtLogin: SetLaunchAtLoginHandler
    private var elapsedTimer: Timer?
    private weak var elapsedMenuItem: NSMenuItem?
    /// The Settings submenu's "Refresh projects & tasks" row, whose second line shows "Last
    /// refreshed at …". Tracked the same way as `elapsedMenuItem` so `silentlyRefreshIfStale()`
    /// can update this one row's title in place when its refresh completes while the menu is
    /// open, rather than needing a full `rebuild()` (which is guarded out while open) — without
    /// this, a menu-open-triggered refresh could never be reflected until the *next* open.
    private weak var lastRefreshedMenuItem: NSMenuItem?
    private var isLoggingIn = false
    private var isChangingLaunchAtLogin = false
    private var isSilentlyRefreshing = false
    private let now: () -> Date
    private var appearanceObservation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?
    /// True while the status item's menu is open on screen. A `rebuild()` while this is true
    /// would repoint `elapsedMenuItem` at a menu instance nobody's looking at, freezing the
    /// displayed menu's live elapsed-time line for the rest of that open session — see the guard
    /// in `rebuild()`.
    private var isMenuOpen = false

    /// Exposed for tests to inspect the live NSStatusItem's menu/icon.
    public var statusItemForTesting: NSStatusItem { statusItem }

    /// Exposed so tests can fire the elapsed-time tick rather than wait a second for it.
    var elapsedTimerForTesting: Timer? { elapsedTimer }

    /// Invoked after a successful `appState.logOut()`, e.g. to clear stored credentials.
    public var onLogOut: (() -> Void)?

    public init(
        appState: AppState,
        dataStore: DataStore,
        statusBar: NSStatusBar = .system,
        performLogin: @escaping LoginHandler = {},
        setLaunchAtLogin: @escaping SetLaunchAtLoginHandler = { _ in false },
        now: @escaping () -> Date = Date.init
    ) {
        self.appState = appState
        self.dataStore = dataStore
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        self.performLogin = performLogin
        self.setLaunchAtLogin = setLaunchAtLogin
        self.now = now
        appState.onChange = { [weak self] in self?.rebuild() }
        rebuild()

        // The tracking icon's hands are non-template (they carry real color, unlike the
        // idle icon), so they don't get the automatic light/dark recoloring template images
        // do — this observation is what keeps them legible when the user flips System
        // Appearance, or the menu bar's own contrast, while a timer is running.
        appearanceObservation = self.statusItem.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // AppKit delivers view-property KVO on the main thread; this mirrors the
            // `MainActor.assumeIsolated` justification already used for the elapsed-time timer.
            MainActor.assumeIsolated {
                self?.updateIcon()
            }
        }

        // A sleeping Mac is the single biggest source of staleness — a timer stopped elsewhere
        // hours ago wouldn't otherwise be caught until the next menu open. Gated by the same
        // `silentlyRefreshIfStale()` threshold as the menu-open trigger, so rapid sleep/wake
        // (e.g. lid flutter) doesn't fire repeated requests.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // queue: nil makes NotificationCenter invoke this block synchronously on the
            // posting thread rather than asynchronously via OperationQueue.main — and
            // NSWorkspace.didWakeNotification is posted on the main thread, so this always runs
            // there. (queue: .main would instead hop through OperationQueue.main, making
            // delivery asynchronous relative to the post — indistinguishable in the running app,
            // but it made tests posting this notification directly unable to rely on a fixed
            // number of drain yields.) This mirrors the `MainActor.assumeIsolated` justification
            // already used for the appearance observation: the closure type itself isn't
            // statically MainActor-isolated, but the runtime guarantees main-thread delivery.
            MainActor.assumeIsolated {
                self?.silentlyRefreshIfStale()
            }
        }
    }

    deinit {
        elapsedTimer?.invalidate()
        appearanceObservation?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private lazy var actions: MenuActions = MenuActions(
        logIn: { [weak self] in
            guard let self, !self.isLoggingIn else { return }
            self.isLoggingIn = true
            Task { @MainActor in
                defer { self.isLoggingIn = false }
                do {
                    try await self.performLogin()
                    // Refresh BEFORE flipping appState to logged-in: if the fetch fails we're
                    // still honestly in the logged-out state (so "Couldn't log in" is accurate
                    // and the Log In item is still there to retry), and the user never sees a
                    // flash of a logged-in-but-empty menu in the success case either.
                    try await self.dataStore.refresh()
                    self.appState.logIn()
                    // Same restore the launch path does — without this, logging out and back in
                    // while a FreeAgent timer runs showed idle, while quit-and-relaunch showed
                    // tracking, from identical server state.
                    self.appState.reconcile(with: self.dataStore)
                    self.rebuild()
                    self.presentLoginSucceeded()
                } catch where error.indicatesLoginCancelled {
                    // The user declined; they know it didn't finish.
                } catch {
                    // Not `presentAPIError`: there's no session yet to have expired, so a 401 here
                    // must not be described as one — "Ratchet signed you out" would be a lie about
                    // someone never signed in.
                    self.presentLoginFailedError(error)
                }
            }
        },
        logOut: { [weak self] in
            // Deferred for the same AppKit reason as the form prompts: running a modal
            // synchronously from inside menu action dispatch can leave the alert non-key.
            DispatchQueue.main.async { self?.confirmAndLogOut() }
        },
        startTracking: { [weak self] task in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let timeslip = try await self.dataStore.startTimer(
                        taskId: task.taskId, projectId: task.projectId, clientId: task.clientId
                    )
                    // `startTimer` stamps a fresh start for a genuinely new (or resumed-from-stopped)
                    // timer, but its same-task resume branch forwards the server's own
                    // `timerStartedAt` unchanged, which is nil whenever the running-view response
                    // omitted the timer object. The coalesce then re-bases a possibly long-running
                    // timer to now, understating its elapsed time — but that's still the least-bad
                    // outcome available here: the alternative is inventing a start instant with no
                    // basis at all, e.g. the old midnight fallback that read as hours elapsed.
                    self.appState.startTracking(task, startedAt: timeslip.timerStartedAt ?? self.now())
                } catch {
                    self.presentAPIError(error, action: "start tracking")
                }
            }
        },
        stopTracking: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.dataStore.stopTimer()
                    self.appState.stopTracking()
                } catch {
                    self.presentAPIError(error, action: "stop tracking")
                }
            }
        },
        switchTask: { [weak self] task in
            guard let self else { return }
            Task { @MainActor in
                do {
                    // Reassigns the *running* timeslip's task in place (a PUT on its task/
                    // project/client, same hours/date/comment) rather than stopping and
                    // starting a new one — the point of "Switch task" is to keep tracking
                    // continuously against a different task, not to end one entry and begin
                    // another. Stop+restart was the first implementation, but it split what the
                    // user experiences as one continuous stretch of work into two timeslips.
                    //
                    // Read from the server, not from `currentRunningTimeslip`: `updateTimeslip`
                    // sends the complete record, so the hours and day sent here are
                    // *asserted*, not merged. Sending the cache's values overwrote anything the
                    // server had accrued since the last refresh — a pause and resume from the
                    // web app silently lost the hours in between.
                    guard let running = try await self.dataStore.runningTimeslip() else {
                        self.presentAPIError(DataStoreError.notFound, action: "switch tasks")
                        return
                    }
                    _ = try await self.dataStore.updateTimeslip(
                        id: running.id,
                        taskId: task.taskId, projectId: task.projectId, clientId: task.clientId,
                        date: running.day, hours: running.hours, comment: running.comment
                    )
                    // Reassigns `appState.trackingTask` without disturbing `trackingStartedAt`
                    // — the timer never stopped, so the elapsed-time display must keep counting
                    // from its original start instant, not reset to now.
                    self.appState.retask(task)
                } catch {
                    self.presentAPIError(error, action: "switch tasks")
                }
            }
        },
        refresh: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.dataStore.refresh()
                    // Same adoption the launch and login paths do — without this, a timer started
                    // elsewhere (the FreeAgent web app, another device) after this app was already
                    // logged in never appeared here even after a manual refresh, because
                    // dataStore.currentRunningTimeslip updating doesn't by itself touch appState.
                    self.appState.reconcile(with: self.dataStore)
                    self.rebuild()
                } catch {
                    self.presentAPIError(error, action: "refresh")
                }
            }
        },
        toggleLaunchAtLogin: { [weak self] in
            guard let self, !self.isChangingLaunchAtLogin else { return }
            self.isChangingLaunchAtLogin = true
            let wanted = !self.appState.launchAtLoginEnabled
            Task { @MainActor in
                defer { self.isChangingLaunchAtLogin = false }
                do {
                    // Flip `appState` to whatever `SMAppService` actually achieved, not what was
                    // asked for — e.g. it stays unchecked if registration is blocked by a system
                    // policy, or left pending approval in System Settings.
                    let actuallyEnabled = try await self.setLaunchAtLogin(wanted)
                    self.appState.setLaunchAtLogin(actuallyEnabled)
                    // register() can succeed (no throw) yet still land in .requiresApproval — the
                    // checkbox reverting on its own with no explanation reads as a broken toggle,
                    // so name the actual reason instead of leaving it silent.
                    if wanted && !actuallyEnabled {
                        self.presentLaunchAtLoginNeedsApproval()
                    }
                } catch {
                    self.presentAPIError(error, action: "change Launch at Login")
                }
            }
        },
        openFreeAgent: { [weak self] in
            let url = self?.dataStore.webAppURL ?? URL(string: "https://app.freeagent.com")!
            NSWorkspace.shared.open(url)
        },
        sendFeedback: {
            NSWorkspace.shared.open(FeedbackURL.newIssue())
        },
        addTask: { [weak self] clientId, projectId in
            self?.presentAddTaskPrompt(clientId: clientId, projectId: projectId)
        },
        addClient: { [weak self] in
            self?.presentAddClientForm()
        },
        addProject: { [weak self] clientId in
            self?.presentAddProjectForm(clientId: clientId)
        },
        logPastTime: { [weak self] clientId, projectId, taskId in
            self?.presentLogPastTimeForm(clientId: clientId, projectId: projectId, taskId: taskId)
        },
        logPastTimeForNewTask: { [weak self] clientId, projectId in
            self?.presentLogPastTimeForNewTaskForm(clientId: clientId, projectId: projectId)
        },
        switchToNewTask: { [weak self] clientId, projectId in
            self?.presentAddTaskPrompt(clientId: clientId, projectId: projectId, switchingFromRunningTimer: true)
        },
        editTimeEntry: { [weak self] entry in
            self?.presentEditTimeEntryForm(entry: entry)
        },
        quit: {
            NSApp.terminate(nil)
        }
    )

    /// Drops local session state and clears stored credentials via `onLogOut`. The single place
    /// "log out" happens, so the menu-driven Log Out and the forced logout below can't diverge.
    private func performLogOut(forgettingMostRecent: Bool = true) {
        appState.logOut(forgettingMostRecent: forgettingMostRecent)
        onLogOut?()
    }

    /// The menu-driven Log Out. Logging out does not stop the FreeAgent timer — the timeslip
    /// goes on accruing billable hours server-side with nothing left in the menu to say so —
    /// so a running timer gets a confirmation naming it rather than a silent abandonment.
    private func confirmAndLogOut() {
        if case .tracking(let task, _) = appState.screen {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A timer is still running"
            alert.informativeText = "Logging out won't stop the timer for \(task.taskName) — it will keep recording time in FreeAgent. Stop it first if that's not what you want."
            alert.addButton(withTitle: "Log Out Anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        performLogOut()
    }

    /// Forces a logout after the session turned out to be dead, then tells the user once.
    /// Exposed so `AppDelegate`'s launch-time restore can route an `.unauthorized` here rather
    /// than swallowing it and leaving a logged-in-looking, permanently empty menu.
    public func handleSessionExpired() {
        // Callers sharing one failed refresh each report it, and the user should hear it once.
        guard appState.isLoggedIn else { return }
        // Unlike a routine silent-refresh success, this is already maximally disruptive — a
        // modal alert is about to steal focus and force the user out of whatever they were
        // doing. There's no "next open" to defer to here (and the modal makes the still-open
        // native menu moot regardless), so this bypasses `rebuild()`'s isMenuOpen guard rather
        // than leaving the menu showing stale logged-in content behind/under the alert.
        isMenuOpen = false
        // The same account usually signs straight back in, so its task is kept for it;
        // `reconcile(with:)` drops the task if a different account signs in instead.
        performLogOut(forgettingMostRecent: false)
        rebuild()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Signed out of FreeAgent"
        alert.informativeText = "Your FreeAgent session has expired, so Ratchet signed you out. Choose \"Log in with browser\" to reconnect."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Without this, a successful login has no feedback of its own — the only sign anything
    /// happened is that the menu's contents are different next time it's opened.
    private func presentLoginSucceeded() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = Self.formIcon
        alert.messageText = "Signed in to FreeAgent"
        alert.informativeText = "Signed in as \(dataStore.accountEmail)."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// A login attempt that never got as far as an established session failing is a different
    /// event from an established session going bad — see the call site in `logIn`'s catch block.
    private func presentLoginFailedError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't sign in to FreeAgent"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// macOS requires explicit user approval in System Settings the first time an app registers
    /// a login item — `register()` doesn't throw for this, so without this alert the checkbox
    /// would just silently revert with no way for the user to tell "pending approval" apart from
    /// "the toggle is broken."
    private func presentLaunchAtLoginNeedsApproval() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Launch at Login needs approval"
        alert.informativeText = "macOS needs you to approve this in System Settings > General > Login Items before Ratchet will launch at login."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentAPIError(_ error: Error, action: String) {
        // A dead session isn't a per-action failure — no amount of retrying "start tracking"
        // fixes it. Clear the credentials, drop to the logged-out menu, and say so once, instead
        // of showing "Couldn't start tracking: session expired" over a still-logged-in menu with
        // no way to re-trigger login.
        if error.indicatesSessionExpired {
            handleSessionExpired()
            return
        }
        if let caveat = error as? DataStoreError, caveat.isUnconfirmed {
            presentUnconfirmed(caveat)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't \(action)"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// A create FreeAgent didn't confirm isn't titled as a failure, for the reason
    /// `presentLoggedConfirmation` gives. `note` follows the explanation.
    private func presentUnconfirmed(_ caveat: DataStoreError, note: String? = nil) {
        presentFormOutcome("Not Confirmed", ["\(caveat)", note].compactMap { $0 }.joined(separator: " "))
    }

    /// What became of a form's create, under the forms' icon.
    private func presentFormOutcome(_ title: String, _ text: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.icon = Self.formIcon
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Rebuilds the menu from the current `appState`/`dataStore` contents. Exposed for callers
    /// (e.g. `AppDelegate`'s launch-time restore) that mutate `dataStore` directly — such
    /// mutations don't route through `appState.onChange`, so the menu wouldn't otherwise
    /// reflect them until the next `appState` change or a manual "Refresh" click.
    public func refreshMenu() {
        rebuild()
    }

    private func rebuild() {
        // While the menu is open, the *displayed* menu is the existing NSMenu instance — handing
        // it a freshly built replacement here would repoint `elapsedMenuItem` at a menu nobody's
        // looking at, and the live elapsed-time line would silently stop updating for the rest of
        // that open session (see `updateTimer()`). Skip the whole rebuild rather than guard just
        // `statusItem.menu`, since `appState.reconcile(with:)` can itself trigger a further `rebuild()`
        // via `appState.onChange` — this one guard covers every rebuild source while open. The
        // next open is unaffected: `menuDidClose` below runs a catch-up `rebuild()` the moment
        // the menu closes, once `isMenuOpen` is false again, so by the time the user reopens it
        // the menu already reflects everything a skipped rebuild would have shown.
        guard !isMenuOpen else { return }
        let menu = MenuBuilder.build(state: appState, dataStore: dataStore, actions: actions, now: now)
        menu.delegate = menuOpenDelegate
        statusItem.menu = menu
        if case .tracking = appState.screen {
            // Index 0 is the disabled elapsed-time line built by MenuBuilder.buildTracking.
            elapsedMenuItem = menu.items[0]
        } else {
            elapsedMenuItem = nil
        }
        lastRefreshedMenuItem = menu.item(withTitle: "Settings")?.submenu.flatMap(MenuBuilder.refreshItem(in:))
        attachLazySubmenuDelegates(to: menu)
        updateIcon()
        updateTooltip()
        updateTimer()
    }

    /// Repopulates a submenu from current `dataStore` contents each time AppKit is about to show
    /// it, so a refresh that lands while the menu is open is visible in it. `rebuild()` can't do
    /// that: it skips while `isMenuOpen`, since a new NSMenu would strand `elapsedMenuItem` and
    /// freeze the elapsed-time line. The top-level rows stay as they were for the rest of that
    /// open, until `menuDidClose`'s catch-up `rebuild()`.
    private final class LazySubmenuDelegate: NSObject, NSMenuDelegate {
        private let populate: (NSMenu) -> Void

        init(populate: @escaping (NSMenu) -> Void) {
            self.populate = populate
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            populate(menu)
        }
    }

    /// `NSMenu.delegate` is `weak`, so the delegates have to outlive the call that installs them.
    /// Replaced wholesale on each `rebuild()`, which discards the previous menu's along with it.
    private var lazySubmenuDelegates: [LazySubmenuDelegate] = []

    /// Points the store-driven submenus at `LazySubmenuDelegate` so each rebuilds on open.
    /// Settings is deliberately excluded: `silentlyRefreshIfStale()` holds a `lastRefreshedMenuItem`
    /// reference into it and updates that row in place (including the transient "Refreshing…"),
    /// which a repopulate would throw away mid-flight.
    private func attachLazySubmenuDelegates(to menu: NSMenu) {
        lazySubmenuDelegates = []
        let builders: [String: () -> NSMenu] = [
            "Start timer": { [weak self] in
                guard let self else { return NSMenu() }
                // The converse of "Switch task" below: a mid-open refresh that adopts a timer
                // started elsewhere leaves the idle screen's picker on show, and starting a
                // different task from it would fail server-side.
                if case .tracking = self.appState.screen {
                    return Self.notice("A timer is already running")
                }
                return MenuBuilder.buildStartSubmenu(dataStore: self.dataStore, actions: self.actions)
            },
            "Log past time": { [weak self] in
                guard let self else { return NSMenu() }
                return MenuBuilder.buildLogPastTimeSubmenu(dataStore: self.dataStore, actions: self.actions)
            },
            "Recent time entries": { [weak self] in
                guard let self else { return NSMenu() }
                return MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: self.dataStore, actions: self.actions)
            },
            "Switch task": { [weak self] in
                guard let self else { return NSMenu() }
                // A mid-open refresh can find the timer stopped elsewhere, leaving this row on
                // screen with nothing to switch; an empty NSMenu would render as a blank popup.
                guard case .tracking(let task, _) = self.appState.screen else {
                    return Self.notice("Timer is no longer running")
                }
                return MenuBuilder.buildSwitchTaskSubmenu(
                    dataStore: self.dataStore, actions: self.actions, currentTaskId: task.taskId
                )
            },
        ]
        for (title, build) in builders {
            guard let submenu = menu.item(withTitle: title)?.submenu else { continue }
            let delegate = LazySubmenuDelegate { menu in
                Self.replaceItems(of: menu, withThoseOf: build())
            }
            submenu.delegate = delegate
            lazySubmenuDelegates.append(delegate)
        }
    }

    /// A submenu holding one disabled row, for a picker the state has moved on from.
    private static func notice(_ title: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuBuilder.disabledItem(title))
        return menu
    }

    /// Moves `fresh`'s items into `menu`, so the displayed NSMenu instance keeps its identity
    /// (AppKit is already showing it) while its contents are replaced. The items have to be
    /// *removed* from `fresh` first — an NSMenuItem can only belong to one menu, and adding one
    /// that still has a `menu` back-pointer is undefined.
    private static func replaceItems(of menu: NSMenu, withThoseOf fresh: NSMenu) {
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    /// `NSMenu.delegate` is an Objective-C protocol, so forwarding `menuWillOpen`/`menuDidClose`
    /// needs an `NSObject`-rooted type — `StatusItemController` itself stays a plain Swift class
    /// rather than picking up `NSObject` for this alone. `NSMenu.delegate` is `weak`, so this
    /// must be held strongly somewhere for the menu's lifetime; `rebuild()` assigns it to every
    /// freshly built menu.
    private final class MenuOpenDelegate: NSObject, NSMenuDelegate {
        private let onOpen: () -> Void
        private let onClose: () -> Void

        init(onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
            self.onOpen = onOpen
            self.onClose = onClose
        }

        func menuWillOpen(_ menu: NSMenu) {
            onOpen()
        }

        func menuDidClose(_ menu: NSMenu) {
            onClose()
        }
    }

    private lazy var menuOpenDelegate = MenuOpenDelegate(
        onOpen: { [weak self] in
            guard let self else { return }
            self.isMenuOpen = true
            self.silentlyRefreshIfStale()
        },
        onClose: { [weak self] in
            guard let self else { return }
            self.isMenuOpen = false
            // Catches up on any rebuild that was skipped by `rebuild()`'s `isMenuOpen` guard
            // while this menu was open (e.g. a silent refresh completing mid-session), so the
            // next time the user opens the menu it's already showing fresh data.
            self.rebuild()
        }
    )

    /// Two minutes: long enough that opening the menu twice in quick succession, or a rapid
    /// sleep/wake, doesn't fire a second network round-trip; short enough that data is never
    /// stale for long while the app is actually being used.
    private static let staleRefreshThreshold: TimeInterval = 120

    /// Shared by the menu-open and system-wake triggers. Skips the network round-trip entirely
    /// if `dataStore` was already refreshed within `staleRefreshThreshold`. Never blocks the
    /// caller — the menu (or whatever triggered this) is already visible/handled by the time
    /// this returns; a successful refresh's `rebuild()` just makes the *next* open reflect fresh
    /// data. The manual "Refresh projects & tasks" item bypasses this entirely by calling
    /// `dataStore.refresh()` directly, so it's never subject to this gate.
    private func silentlyRefreshIfStale() {
        // No session means nothing to silently refresh — without this, a logged-out
        // `dataStore.lastRefreshedAt` (nil, since it's never been fetched) reads as "stale" and
        // falls through to `dataStore.refresh()`, which throws `.unauthorized` for a simple
        // never-logged-in state exactly as it would for a dead session, triggering the "your
        // session expired" alert on every menu open and wake. Mirrors `AppDelegate`'s
        // `if tokenStore.load() != nil` guard on the launch-time refresh, same reasoning.
        guard appState.isLoggedIn else { return }
        // A local write since the last refresh means the cache is known-stale regardless of how
        // recently it was fetched, so the age check doesn't get to skip this — see
        // `DataStore.hasLocalWritesSinceRefresh`.
        if !dataStore.hasLocalWritesSinceRefresh,
           let lastRefreshedAt = dataStore.lastRefreshedAt,
           now().timeIntervalSince(lastRefreshedAt) < Self.staleRefreshThreshold {
            return
        }
        // Guards against the ordinary "wake, then immediately open the menu" sequence starting a
        // second concurrent refresh while the wake-triggered one is still in flight (this flag,
        // not `lastRefreshedAt`, is what's current until the Task below completes).
        guard !isSilentlyRefreshing else { return }
        isSilentlyRefreshing = true
        // Set synchronously, still on the call stack from `menuWillOpen`, so the row reads
        // "Refreshing…" for the whole time this is in flight instead of showing the pre-refresh
        // timestamp with no sign anything is happening. Disabled so it can't kick off a second
        // refresh (or race the manual "Refresh projects & tasks" handler) while this one's live.
        lastRefreshedMenuItem?.attributedTitle = MenuBuilder.refreshingAttributedTitle()
        lastRefreshedMenuItem?.isEnabled = false
        Task { @MainActor in
            defer { self.isSilentlyRefreshing = false }
            do {
                try await self.dataStore.refresh()
                // Same adoption the manual refresh and launch/login paths do — without this, a
                // timer started or stopped elsewhere wouldn't show up even after this silent
                // refresh succeeds.
                self.appState.reconcile(with: self.dataStore)
                // A menu open in progress must not have its live elapsed-time line yanked out
                // from under it — see the guard inside `rebuild()`. But this row isn't
                // menu-instance-dependent the way `elapsedMenuItem` is, so it's updated in place
                // here even while `isMenuOpen`, rather than leaving it stuck on
                // "Refreshing…"/disabled until the next open's catch-up `rebuild()`.
                self.lastRefreshedMenuItem?.attributedTitle = MenuBuilder.refreshItemAttributedTitle(
                    lastRefreshedAt: self.dataStore.lastRefreshedAt
                )
                self.lastRefreshedMenuItem?.isEnabled = true
                self.rebuild()
            } catch where error.indicatesSessionExpired {
                self.handleSessionExpired()
            } catch {
                // A background refresh failing (e.g. no network) isn't worth interrupting the
                // user over — same reasoning as AppDelegate's launch-time refresh. The next
                // menu open or wake just tries again. Still needs to leave the row usable again
                // rather than stuck on "Refreshing…"/disabled — `dataStore.lastRefreshedAt` is
                // unchanged, so this reverts to exactly what it showed before this attempt.
                self.lastRefreshedMenuItem?.attributedTitle = MenuBuilder.refreshItemAttributedTitle(
                    lastRefreshedAt: self.dataStore.lastRefreshedAt
                )
                self.lastRefreshedMenuItem?.isEnabled = true
            }
        }
    }

    /// The tray glyph's point size. NSStatusItem draws button images at roughly this size
    /// regardless of the source image's declared size, but `RatchetIcon.mark` renders vector
    /// paths scaled to whatever size is requested, so this is what determines crispness.
    private static let trayIconSize: CGFloat = 18

    /// Whether the menu bar is currently dark. The bezel's green fill has enough contrast
    /// against both light and dark bars on its own; only the hands — which cross an open
    /// cutout in the middle of the bezel, not the green fill — need to flip for contrast.
    private var isDarkMenuBar: Bool {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func updateIcon() {
        let isTracking: Bool
        if case .tracking = appState.screen { isTracking = true } else { isTracking = false }
        if isTracking {
            let handColor: NSColor = isDarkMenuBar ? .white : .black
            let image = RatchetIcon.mark(
                size: Self.trayIconSize, bezelColor: RatchetIcon.trackingGreen, handColor: handColor
            )
            image.accessibilityDescription = "Ratchet"
            // Non-template so the green survives — NSStatusItem flattens template images to
            // the menu bar's monochrome tint, which would erase the color. That's also why the
            // hand color above isn't automatic and needs `isDarkMenuBar` to pick it explicitly.
            image.isTemplate = false
            statusItem.button?.image = image
        } else {
            // Template: a single opaque color is fine (only alpha is used) since NSStatusItem
            // recolors the whole image to match the menu bar's current light/dark tint.
            let image = RatchetIcon.mark(size: Self.trayIconSize, bezelColor: .black, handColor: .black)
            image.accessibilityDescription = "Ratchet"
            image.isTemplate = true
            statusItem.button?.image = image
        }
    }

    /// Hover text for the tray icon, shown before the menu is opened. Mirrors the open menu's
    /// own top-to-bottom order — elapsed time, then task, then client/project — so hovering and
    /// opening never disagree about what's running.
    private static func tooltip(for screen: Screen, elapsedNow: Date) -> String? {
        switch screen {
        case .loggedOut:
            return nil
        case .idleNoHistory, .idle:
            return "Idle"
        case .tracking(let task, let startedAt):
            let elapsed = ElapsedTimeFormatter.format(seconds: elapsedNow.timeIntervalSince(startedAt))
            return "\(elapsed)\nTracking \(task.taskName)\n\(task.clientName) · \(task.projectName)"
        }
    }

    private func updateTooltip() {
        statusItem.button?.toolTip = Self.tooltip(for: appState.screen, elapsedNow: now())
    }

    private func updateTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if case .tracking(_, let startedAt) = appState.screen {
            // Taken with `startedAt`, so the row describes the timeslip the rest of its menu was
            // built from: an open menu isn't rebuilt when a refresh adopts a different one.
            let bookedDay = dataStore.currentRunningTimeslip?.day
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                // Scheduled on RunLoop.main below, so this always fires on the main thread;
                // `assumeIsolated` tells the compiler what the runtime already guarantees.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard case .tracking = self.appState.screen else { return }
                    self.elapsedMenuItem?.title = MenuBuilder.elapsedItemTitle(
                        startedAt: startedAt, bookedDay: bookedDay, now: self.now()
                    )
                    // The tooltip's own elapsed line needs the same per-second tick as the
                    // menu row above — otherwise it goes stale the moment it's first shown.
                    self.updateTooltip()
                }
            }
            // Menus run the run loop in .eventTracking mode while open (the only time the
            // elapsed line is visible), so .common is required for the tick to fire then.
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
        }
    }

    private func presentAddTaskPrompt(clientId: String, projectId: String, switchingFromRunningTimer: Bool = false) {
        // Defer until the menu-tracking run loop session has unwound: running a modal
        // session synchronously from inside menu action dispatch is a known AppKit hazard
        // (the alert can appear behind/non-key, or interact oddly with the just-closed menu).
        DispatchQueue.main.async { [weak self] in
            self?.runAddTaskPrompt(clientId: clientId, projectId: projectId, switchingFromRunningTimer: switchingFromRunningTimer)
        }
    }

    /// Shared field set for both the standalone "New Task" prompt and the combined
    /// "New Task + Log Time" prompt reachable from Log Past Time's task drill-down.
    private struct TaskFields {
        let rows: [NSView]
        let nameField: NSTextField
        let billableCheckbox: NSButton
        let statusPopup: NSPopUpButton
        let billingRateField: NSTextField
        let billingPeriodPopup: NSPopUpButton
    }

    private func makeTaskFields(controlWidth: CGFloat) -> TaskFields {
        let nameField = NSTextField(frame: .zero)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "Task name"
        nameField.toolTip = "The task's name, as it'll appear when tracking time against it."
        nameField.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        let statusPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        statusPopup.translatesAutoresizingMaskIntoConstraints = false
        statusPopup.addItems(withTitles: TaskStatus.allCases.map(\.rawValue))
        statusPopup.toolTip = "Whether the task is currently active, completed, or hidden from most views."
        statusPopup.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        let billingRateField = NSTextField(frame: .zero)
        billingRateField.translatesAutoresizingMaskIntoConstraints = false
        billingRateField.placeholderString = "Uses project's rate"
        billingRateField.toolTip = "Override the project's normal billing rate for just this task. Leave blank to use the project's rate."
        billingRateField.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        let billingPeriodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        billingPeriodPopup.translatesAutoresizingMaskIntoConstraints = false
        billingPeriodPopup.addItems(withTitles: BillingPeriod.allCases.map(\.rawValue))
        billingPeriodPopup.toolTip = "Whether the billing rate above (if set) is per hour or per day."
        billingPeriodPopup.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        let billableCheckbox = NSButton(checkboxWithTitle: "Billable", target: nil, action: nil)
        billableCheckbox.state = .on
        billableCheckbox.toolTip = "Whether time tracked on this task can be billed to the client."

        let rows: [NSView] = [
            labeledRow("Name *", nameField, required: true),
            labeledRow("Status", statusPopup),
            labeledRow("Billing rate", billingRateField),
            labeledRow("Billing period", billingPeriodPopup),
            billableCheckbox,
        ]
        return TaskFields(
            rows: rows,
            nameField: nameField,
            billableCheckbox: billableCheckbox,
            statusPopup: statusPopup,
            billingRateField: billingRateField,
            billingPeriodPopup: billingPeriodPopup
        )
    }

    /// Shared field set for both Log Past Time prompts (existing task, and combined with
    /// task creation).
    private struct LogTimeFields {
        let rows: [NSView]
        let datePicker: NSDatePicker
        let durationField: NSTextField
        let commentField: NSTextField
    }

    private func makeLogTimeFields(controlWidth: CGFloat) -> LogTimeFields {
        let datePicker = NSDatePicker(frame: .zero)
        datePicker.translatesAutoresizingMaskIntoConstraints = false
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay]
        datePicker.controlSize = .large
        datePicker.dateValue = Date()
        datePicker.maxDate = Date()
        datePicker.toolTip = "The date this time was worked."
        datePicker.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        let durationField = NSTextField(frame: .zero)
        durationField.translatesAutoresizingMaskIntoConstraints = false
        durationField.placeholderString = "H:MM"
        durationField.toolTip = "How long you worked, as hours:minutes (e.g. 1:30 for an hour and a half). Max 24:00."
        durationField.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        let commentField = NSTextField(frame: .zero)
        commentField.translatesAutoresizingMaskIntoConstraints = false
        commentField.placeholderString = "Comment (optional)"
        commentField.toolTip = "An optional note about what this time was for."
        commentField.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        let rows: [NSView] = [
            labeledRow("Date *", datePicker, required: true),
            labeledRow("Duration *", durationField, required: true),
            labeledRow("Comment", commentField),
        ]
        return LogTimeFields(rows: rows, datePicker: datePicker, durationField: durationField, commentField: commentField)
    }

    /// Whether the billing rate field currently holds something acceptable — blank (inherit the
    /// project's rate) or a non-negative number.
    ///
    /// Separate from `parseOptionalBillingRate` because that one reports failure by throwing up
    /// an alert, which is exactly wrong for the per-keystroke check that gates the confirm
    /// button. `parseOptionalBillingRate` calls this rather than re-deriving the rule, so the
    /// two can't diverge.
    private static func isValidOptionalBillingRate(_ field: NSTextField) -> Bool {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        guard let parsed = Double(text) else { return false }
        return parsed >= 0
    }

    /// Parses the billing rate field: blank means "inherit the project's rate" (nil),
    /// otherwise it must be a non-negative number. Returns nil (with an error shown) if invalid.
    ///
    /// Unreachable in practice now that the confirm button is disabled while the field is
    /// invalid — kept as the real parse, and as a backstop.
    private func parseOptionalBillingRate(_ field: NSTextField) -> Double?? {
        guard Self.isValidOptionalBillingRate(field) else {
            presentValidationError("Billing rate must be zero or more, or left blank to use the project's rate.")
            return nil
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .some(nil) : .some(Double(text))
    }

    private func runAddTaskPrompt(clientId: String, projectId: String, switchingFromRunningTimer: Bool = false) {
        let alert = NSAlert()
        alert.icon = Self.formIcon
        alert.messageText = "New Task"
        let addButton = alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let controlWidth: CGFloat = 180
        let fields = makeTaskFields(controlWidth: controlWidth)
        let nameField = fields.nameField
        let billableCheckbox = fields.billableCheckbox
        let statusPopup = fields.statusPopup
        let billingRateField = fields.billingRateField
        let billingPeriodPopup = fields.billingPeriodPopup

        let stack = NSStackView(views: fields.rows)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        alert.accessoryView = Self.frameBasedContainer(wrapping: stack)
        alert.window.initialFirstResponder = nameField
        // Billing rate is watched too, not just the name: leaving it out let "Add" stay enabled
        // over an unparseable rate, so the sheet dismissed and *then* complained — taking the
        // name, status and billing period down with it.
        let observers = liveValidate(button: addButton, fields: [nameField, billingRateField]) {
            guard TaskNameValidator.validate(nameField.stringValue) != nil else { return false }
            return Self.isValidOptionalBillingRate(billingRateField)
        }
        // The app runs as .accessory and is not the active app when a status-bar item is
        // clicked, so the alert can appear non-key/non-frontmost without this.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        endLiveValidate(observers)
        guard response == .alertFirstButtonReturn, let name = TaskNameValidator.validate(nameField.stringValue) else { return }

        guard let status = TaskStatus(rawValue: statusPopup.titleOfSelectedItem ?? ""),
              let billingPeriod = BillingPeriod(rawValue: billingPeriodPopup.titleOfSelectedItem ?? "") else {
            presentValidationError("Select a status and billing period.")
            return
        }
        guard let billingRate = parseOptionalBillingRate(billingRateField) else { return }

        Task { @MainActor in
            let task: RatchetTask
            do {
                task = try await self.dataStore.addTask(
                    name: name,
                    projectId: projectId,
                    clientId: clientId,
                    isBillable: billableCheckbox.state == .on,
                    status: status,
                    billingRate: billingRate,
                    billingPeriod: billingRate == nil ? nil : billingPeriod
                )
            } catch let caveat as DataStoreError where caveat.isUnconfirmed {
                let note = switchingFromRunningTimer
                    ? "The running timer is still on its previous task." : "Tracking hasn't started."
                self.presentUnconfirmed(caveat, note: note)
                return
            } catch {
                self.presentAPIError(error, action: "create the task")
                return
            }
            self.rebuild()

            // "New task…" is reachable from both the Start > drill-down (nothing running yet)
            // and Switch task > drill-down (something already is) — either way, creating one
            // here means the user wants to track it immediately, not just add it. The task
            // itself is already created at this point, so a failure here gets its own message
            // rather than implying the task creation failed too.
            guard let client = self.dataStore.clients.first(where: { $0.id == clientId }),
                  let project = client.projects.first(where: { $0.id == projectId })
            else {
                // Refreshing won't bring back a project the last refresh dropped, so this names the
                // task that now exists rather than suggesting it.
                let gone = DataStoreError.underlying(
                    "\u{201C}\(task.name)\u{201D} was created, but Ratchet no longer lists its project, so it can't track it."
                )
                self.presentAPIError(gone, action: switchingFromRunningTimer ? "switch tasks" : "start tracking the new task")
                return
            }
            let ref = TrackedTaskRef(
                clientId: client.id, clientName: client.name,
                projectId: project.id, projectName: project.name,
                taskId: task.id, taskName: task.name
            )
            do {
                if switchingFromRunningTimer {
                    // See `switchTask`'s comment: reassign the running timeslip's task in
                    // place rather than stopping and starting a new one, so switching to a
                    // freshly-created task keeps the elapsed time continuous too. Same reasoning
                    // as there for reading from the server: the PUT asserts the full record, so
                    // the hours and day must come from the server rather than a cache that may
                    // be minutes old.
                    guard let running = try await self.dataStore.runningTimeslip() else {
                        self.presentAPIError(DataStoreError.notFound, action: "switch tasks")
                        return
                    }
                    _ = try await self.dataStore.updateTimeslip(
                        id: running.id,
                        taskId: task.id, projectId: projectId, clientId: clientId,
                        date: running.day, hours: running.hours, comment: running.comment
                    )
                    self.appState.retask(ref)
                } else {
                    let timeslip = try await self.dataStore.startTimer(taskId: task.id, projectId: projectId, clientId: clientId)
                    self.appState.startTracking(ref, startedAt: timeslip.timerStartedAt ?? self.now())
                }
            } catch {
                self.presentAPIError(error, action: switchingFromRunningTimer ? "switch tasks" : "start tracking the new task")
            }
        }
    }

    private func presentLogPastTimeForm(clientId: String, projectId: String, taskId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.runLogPastTimeForm(clientId: clientId, projectId: projectId, taskId: taskId)
        }
    }

    private func runLogPastTimeForm(clientId: String, projectId: String, taskId: String) {
        let alert = NSAlert()
        alert.icon = Self.formIcon
        alert.messageText = "Log Past Time"
        let logButton = alert.addButton(withTitle: "Log")
        alert.addButton(withTitle: "Cancel")

        let controlWidth: CGFloat = 180
        let fields = makeLogTimeFields(controlWidth: controlWidth)
        let datePicker = fields.datePicker
        let durationField = fields.durationField
        let commentField = fields.commentField

        let stack = NSStackView(views: fields.rows)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        alert.accessoryView = Self.frameBasedContainer(wrapping: stack)
        alert.window.initialFirstResponder = durationField
        let observers = liveValidate(button: logButton, fields: [durationField]) {
            DurationFormatter.parseHoursAndMinutes(durationField.stringValue) != nil
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        endLiveValidate(observers)
        guard response == .alertFirstButtonReturn else { return }

        guard let hours = DurationFormatter.parseHoursAndMinutes(durationField.stringValue) else {
            presentValidationError("Enter a duration as hours:minutes, e.g. 1:30 (max 24:00).")
            return
        }

        Task { @MainActor in
            let taskName = self.dataStore.clients.first(where: { $0.id == clientId })?
                .projects.first(where: { $0.id == projectId })?
                .tasks.first(where: { $0.id == taskId })?
                .name ?? "the task"
            do {
                _ = try await self.dataStore.logTime(
                    taskId: taskId,
                    projectId: projectId,
                    clientId: clientId,
                    date: datePicker.dateValue,
                    hours: hours,
                    comment: TaskNameValidator.validate(commentField.stringValue)
                )
                self.rebuild()
                self.presentLoggedConfirmation(taskName: taskName, hours: hours, date: datePicker.dateValue)
            } catch let caveat as DataStoreError where caveat.qualifiesLoggedEntry {
                self.rebuild()
                self.presentLoggedConfirmation(taskName: taskName, hours: hours, date: datePicker.dateValue, caveat: caveat)
            } catch {
                self.presentAPIError(error, action: "log time")
            }
        }
    }

    private func presentLogPastTimeForNewTaskForm(clientId: String, projectId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.runLogPastTimeForNewTaskForm(clientId: clientId, projectId: projectId)
        }
    }

    private func runLogPastTimeForNewTaskForm(clientId: String, projectId: String) {
        let alert = NSAlert()
        alert.icon = Self.formIcon
        alert.messageText = "New Task"
        alert.informativeText = "Creates the task and logs time against it in one step."
        let createButton = alert.addButton(withTitle: "Create & Log")
        alert.addButton(withTitle: "Cancel")

        let controlWidth: CGFloat = 180
        let taskFields = makeTaskFields(controlWidth: controlWidth)
        let logTimeFields = makeLogTimeFields(controlWidth: controlWidth)
        let nameField = taskFields.nameField
        let billableCheckbox = taskFields.billableCheckbox
        let statusPopup = taskFields.statusPopup
        let billingRateField = taskFields.billingRateField
        let billingPeriodPopup = taskFields.billingPeriodPopup
        let datePicker = logTimeFields.datePicker
        let durationField = logTimeFields.durationField
        let commentField = logTimeFields.commentField

        let stack = NSStackView(views: taskFields.rows + logTimeFields.rows)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        alert.accessoryView = Self.frameBasedContainer(wrapping: stack)
        alert.window.initialFirstResponder = nameField
        // Billing rate is watched here for the same reason as in `runAddTaskPrompt`, and it costs
        // more in this sheet: dismissing on an unparseable rate would discard the name, status,
        // billing period, date, duration *and* comment, all of which live only in these controls.
        let observers = liveValidate(button: createButton, fields: [nameField, billingRateField, durationField]) {
            guard TaskNameValidator.validate(nameField.stringValue) != nil else { return false }
            guard Self.isValidOptionalBillingRate(billingRateField) else { return false }
            guard DurationFormatter.parseHoursAndMinutes(durationField.stringValue) != nil else { return false }
            return true
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        endLiveValidate(observers)
        guard response == .alertFirstButtonReturn, let name = TaskNameValidator.validate(nameField.stringValue) else { return }

        guard let status = TaskStatus(rawValue: statusPopup.titleOfSelectedItem ?? ""),
              let billingPeriod = BillingPeriod(rawValue: billingPeriodPopup.titleOfSelectedItem ?? "") else {
            presentValidationError("Select a status and billing period.")
            return
        }
        guard let billingRate = parseOptionalBillingRate(billingRateField) else { return }
        guard let hours = DurationFormatter.parseHoursAndMinutes(durationField.stringValue) else {
            presentValidationError("Enter a duration as hours:minutes, e.g. 1:30 (max 24:00).")
            return
        }

        Task { @MainActor in
            let newTask: RatchetTask
            do {
                newTask = try await self.dataStore.addTask(
                    name: name,
                    projectId: projectId,
                    clientId: clientId,
                    isBillable: billableCheckbox.state == .on,
                    status: status,
                    billingRate: billingRate,
                    billingPeriod: billingRate == nil ? nil : billingPeriod
                )
            } catch let caveat as DataStoreError where caveat.isUnconfirmed {
                self.presentUnconfirmed(caveat, note: "No time was logged against it.")
                return
            } catch {
                self.presentAPIError(error, action: "create the task")
                return
            }
            self.rebuild()
            // Re-running this form would create the task again, and the time with it, so the
            // outcomes below name the task that now exists and a caveat points a retry at it.
            let createdTask = "the new task \u{201C}\(name)\u{201D}"
            do {
                _ = try await self.dataStore.logTime(
                    taskId: newTask.id,
                    projectId: projectId,
                    clientId: clientId,
                    date: datePicker.dateValue,
                    hours: hours,
                    comment: TaskNameValidator.validate(commentField.stringValue)
                )
                self.rebuild()
                self.presentLoggedConfirmation(taskName: name, hours: hours, date: datePicker.dateValue)
            } catch let caveat as DataStoreError where caveat.qualifiesLoggedEntry {
                self.rebuild()
                self.presentLoggedConfirmation(
                    taskName: createdTask, hours: hours, date: datePicker.dateValue, caveat: caveat,
                    retryAdvice: "Use \u{201C}\(name)\u{201D} under Log past time for that, since New task would create the task again."
                )
            } catch {
                self.presentAPIError(error, action: "log time against \(createdTask)")
            }
        }
    }

    /// `caveat` qualifies an entry that wasn't simply logged (see `qualifiesLoggedEntry`).
    /// Neither is titled as a failure, since a user who reads only the title and logs the time
    /// some other way makes the very duplicate both exist to prevent. `retryAdvice` follows the
    /// caveat, for a form that logging the same entry again must not go through.
    private func presentLoggedConfirmation(
        taskName: String, hours: Double, date: Date, caveat: DataStoreError? = nil, retryAdvice: String? = nil
    ) {
        let duration = ElapsedTimeFormatter.format(seconds: hours * 3600)
        let dateText = Self.confirmationDateFormatter.string(from: date)
        let alert = NSAlert()
        alert.icon = Self.formIcon
        if let caveat {
            alert.messageText = caveat == .alreadyLogged ? "Already Logged" : "Not Confirmed"
            alert.informativeText = ["\(duration) for \(taskName) on \(dateText).", "\(caveat)", retryAdvice]
                .compactMap { $0 }.joined(separator: " ")
            if caveat.isUnconfirmed { alert.alertStyle = .warning }
        } else {
            alert.messageText = "Time Logged"
            alert.informativeText = "\(duration) logged for \(taskName) on \(dateText)."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static let confirmationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Three popups — Client, Project, Task — that keep each other in sync, the direct
    /// equivalent of `MenuBuilder`'s cascading client→project→task submenus for a form context
    /// where nested submenus aren't available. AppKit's target-action needs an `NSObject` to
    /// receive `@objc` selectors, so this owns the re-population wiring between the three
    /// popups rather than that logic living inline in `runEditTimeEntryForm`.
    @MainActor
    private final class CascadingTaskPicker: NSObject {
        let clientPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let projectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let taskPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        private let clients: [RatchetClient]
        /// Fires whenever the user changes any of the three popups (not on programmatic
        /// `select(...)` calls during setup) — the form uses this to tell "the user made an
        /// explicit choice" apart from "this is just the default first item."
        var onChange: (() -> Void)?

        init(clients: [RatchetClient], controlWidth: CGFloat) {
            self.clients = clients
            super.init()
            for popup in [clientPopup, projectPopup, taskPopup] {
                popup.translatesAutoresizingMaskIntoConstraints = false
                popup.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
            }
            clientPopup.toolTip = "Which client this time is booked against."
            projectPopup.toolTip = "Which of the client's projects this time is booked against."
            taskPopup.toolTip = "Which of the project's tasks this time is booked against."
            clientPopup.addItems(withTitles: clients.map(\.name))
            clientPopup.target = self
            clientPopup.action = #selector(clientChanged)
            projectPopup.target = self
            projectPopup.action = #selector(projectChanged)
            taskPopup.target = self
            taskPopup.action = #selector(taskChanged)
            repopulateProjects()
            repopulateTasks()
        }

        var selectedClient: RatchetClient? {
            clients.indices.contains(clientPopup.indexOfSelectedItem) ? clients[clientPopup.indexOfSelectedItem] : nil
        }
        var selectedProject: RatchetProject? {
            guard let client = selectedClient, client.projects.indices.contains(projectPopup.indexOfSelectedItem) else { return nil }
            return client.projects[projectPopup.indexOfSelectedItem]
        }
        var selectedTask: RatchetTask? {
            guard let project = selectedProject, project.tasks.indices.contains(taskPopup.indexOfSelectedItem) else { return nil }
            return project.tasks[taskPopup.indexOfSelectedItem]
        }

        /// Preselects a specific (client, project, task) triple, e.g. the entry being edited's
        /// current assignment. Returns false the moment any part of the triple isn't found in
        /// the current list (an archived project, a deleted task) — the caller decides how to
        /// treat that rather than this silently leaving the popups on whatever they defaulted
        /// to (index 0 of each, once populated).
        func select(clientId: String, projectId: String, taskId: String) -> Bool {
            guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { return false }
            clientPopup.selectItem(at: clientIndex)
            repopulateProjects()
            guard let projectIndex = clients[clientIndex].projects.firstIndex(where: { $0.id == projectId }) else { return false }
            projectPopup.selectItem(at: projectIndex)
            repopulateTasks()
            guard let taskIndex = clients[clientIndex].projects[projectIndex].tasks.firstIndex(where: { $0.id == taskId }) else { return false }
            taskPopup.selectItem(at: taskIndex)
            return true
        }

        @objc private func clientChanged() {
            repopulateProjects()
            repopulateTasks()
            onChange?()
        }

        @objc private func projectChanged() {
            repopulateTasks()
            onChange?()
        }

        @objc private func taskChanged() {
            onChange?()
        }

        private func repopulateProjects() {
            projectPopup.removeAllItems()
            projectPopup.addItems(withTitles: selectedClient?.projects.map(\.name) ?? [])
        }

        private func repopulateTasks() {
            taskPopup.removeAllItems()
            taskPopup.addItems(withTitles: selectedProject?.tasks.map(\.name) ?? [])
        }
    }

    private func presentEditTimeEntryForm(entry: RatchetTimeslip) {
        DispatchQueue.main.async { [weak self] in
            self?.runEditTimeEntryForm(entry: entry)
        }
    }

    private func runEditTimeEntryForm(entry: RatchetTimeslip) {
        let alert = NSAlert()
        alert.icon = Self.formIcon
        alert.messageText = "Edit Time Entry"
        let saveButton = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let controlWidth: CGFloat = 180
        let picker = CascadingTaskPicker(clients: dataStore.clients, controlWidth: controlWidth)
        // When the entry's original task isn't in the current list (its project was archived
        // since the last refresh, or this is an "unknown task" entry with an unresolved
        // clientId), the popups fall back to AppKit's default first-item selection at every
        // level — `matched` tracks that this is *not* the entry's real assignment, so Save stays
        // disabled (see `isValid` below) until the user explicitly picks something themselves.
        let matched = picker.select(clientId: entry.clientId, projectId: entry.projectId, taskId: entry.taskId)
        var selectionConfirmed = matched

        let logTimeFields = makeLogTimeFields(controlWidth: controlWidth)
        let datePicker = logTimeFields.datePicker
        let durationField = logTimeFields.durationField
        let commentField = logTimeFields.commentField
        datePicker.dateValue = entry.day
        durationField.stringValue = DurationFormatter.hoursAndMinutes(entry.hours)
        commentField.stringValue = entry.comment ?? ""

        let rows: [NSView] = [
            labeledRow("Client *", picker.clientPopup, required: true),
            labeledRow("Project *", picker.projectPopup, required: true),
            labeledRow("Task *", picker.taskPopup, required: true),
        ] + logTimeFields.rows
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        alert.accessoryView = Self.frameBasedContainer(wrapping: stack)
        alert.window.initialFirstResponder = durationField
        let isValid: () -> Bool = {
            guard selectionConfirmed, picker.selectedTask != nil else { return false }
            return DurationFormatter.parseHoursAndMinutes(durationField.stringValue) != nil
        }
        let observers = liveValidate(button: saveButton, fields: [durationField], isValid: isValid)
        // Changing any of the three popups counts as an explicit choice — re-validate (which
        // also flips `selectionConfirmed` on for the not-`matched` case) exactly like a
        // keystroke in `durationField` already does via `liveValidate` above.
        picker.onChange = { [weak saveButton] in
            selectionConfirmed = true
            saveButton?.isEnabled = isValid()
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        endLiveValidate(observers)
        guard response == .alertFirstButtonReturn else { return }

        // `rebuild()` is skipped while the menu is open, so the row that opened this sheet came
        // from the menu as it was built — possibly before a silent refresh learned the entry had
        // been invoiced. FreeAgent closes an invoiced entry off, and editing billed time from a
        // stale menu row is the one outcome worse than making the user look again.
        if dataStore.timeslips.first(where: { $0.id == entry.id })?.isInvoiced == true {
            presentValidationError("That entry has been added to an invoice since this menu was opened, so it can no longer be edited here.")
            return
        }

        guard let hours = DurationFormatter.parseHoursAndMinutes(durationField.stringValue) else {
            presentValidationError("Enter a duration as hours:minutes, e.g. 1:30 (max 24:00).")
            return
        }
        // Guarded by `isValid` above (the Save button is disabled otherwise), so only reachable
        // if the selection somehow became invalid between the button enabling and Save being
        // clicked — fail loudly rather than silently keeping (or guessing) the entry's task.
        guard let client = picker.selectedClient, let project = picker.selectedProject, let task = picker.selectedTask else {
            presentValidationError("Select a client, project, and task.")
            return
        }

        Task { @MainActor in
            do {
                _ = try await self.dataStore.updateTimeslip(
                    id: entry.id,
                    taskId: task.id,
                    projectId: project.id,
                    clientId: client.id,
                    date: datePicker.dateValue,
                    hours: hours,
                    comment: TaskNameValidator.validate(commentField.stringValue)
                )
                self.rebuild()

                let taskName = task.name
                self.presentLoggedConfirmation(taskName: taskName, hours: hours, date: datePicker.dateValue)
            } catch {
                self.presentAPIError(error, action: "update the time entry")
            }
        }
    }

    private func presentAddClientForm() {
        DispatchQueue.main.async { [weak self] in
            self?.runAddClientForm()
        }
    }

    private func runAddClientForm() {
        let alert = NSAlert()
        alert.icon = Self.formIcon
        alert.messageText = "New Client"
        alert.informativeText = "Required: an organisation name, or a first and last name. Everything else is optional."
        let createButton = alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let controlWidth: CGFloat = 180

        func makeField(_ placeholder: String, toolTip: String) -> NSTextField {
            let field = NSTextField(frame: .zero)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.placeholderString = placeholder
            field.toolTip = toolTip
            field.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
            return field
        }

        let orgField = makeField("Organisation name", toolTip: "The company or organisation this client represents, e.g. \"Acme Ltd\".")
        let firstNameField = makeField("First name", toolTip: "First name, if this client is an individual rather than an organisation.")
        let lastNameField = makeField("Last name", toolTip: "Last name, if this client is an individual rather than an organisation.")
        let emailField = makeField("name@example.com", toolTip: "The client's main email address.")
        let phoneField = makeField("Phone number", toolTip: "A phone number for this client.")
        let address1Field = makeField("Address line 1", toolTip: "Street address.")
        let townField = makeField("Town / City", toolTip: "Town or city.")
        let postcodeField = makeField("Postcode", toolTip: "Postal or ZIP code.")
        let countryField = makeField("Country", toolTip: "Country.")

        let stack = NSStackView(views: [
            // None of these three is individually required — the rule is "organisation name,
            // OR both first and last name" (see the alert's informativeText above), which the
            // per-field bold-asterisk treatment can't express, so none of them gets it.
            labeledRow("Organisation", orgField),
            labeledRow("First name", firstNameField),
            labeledRow("Last name", lastNameField),
            labeledRow("Email", emailField),
            labeledRow("Phone", phoneField),
            labeledRow("Address", address1Field),
            labeledRow("Town", townField),
            labeledRow("Postcode", postcodeField),
            labeledRow("Country", countryField),
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        alert.accessoryView = Self.frameBasedContainer(wrapping: stack)
        alert.window.initialFirstResponder = orgField
        // Email is watched as well as the name fields: it's the only other thing checked below,
        // and leaving it out meant a typo'd address dismissed the sheet and *then* complained,
        // throwing away all nine fields the user had just filled in. The email itself stays
        // optional, so the test is "blank or plausible" — matching the post-dismiss guard, which
        // only reaches `isPlausibleEmail` once `TaskNameValidator.validate` has ruled out blank.
        // Disagreement between the two would strand the user on a permanently disabled button.
        let observers = liveValidate(button: createButton, fields: [orgField, firstNameField, lastNameField, emailField]) { [self] in
            guard resolvedClientName(
                organisationName: orgField.stringValue,
                firstName: firstNameField.stringValue,
                lastName: lastNameField.stringValue
            ) != nil else { return false }
            guard let email = TaskNameValidator.validate(emailField.stringValue) else { return true }
            return Self.isPlausibleEmail(email)
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        endLiveValidate(observers)
        guard response == .alertFirstButtonReturn else { return }

        let name = resolvedClientName(
            organisationName: orgField.stringValue,
            firstName: firstNameField.stringValue,
            lastName: lastNameField.stringValue
        )
        // `resolvedClientName` still enforces the "organisation name, OR both first and last"
        // rule, but its flattened result is no longer what gets sent — the store takes the
        // fields apart so FreeAgent can tell an organisation from a person.
        guard name != nil else {
            presentValidationError("Enter either an organisation name, or both a first and last name.")
            return
        }
        let email = TaskNameValidator.validate(emailField.stringValue)
        if let email, !Self.isPlausibleEmail(email) {
            presentValidationError("\"\(email)\" doesn't look like a valid email address.")
            return
        }
        Task { @MainActor in
            do {
                _ = try await self.dataStore.addClient(
                    organisationName: TaskNameValidator.validate(orgField.stringValue),
                    firstName: TaskNameValidator.validate(firstNameField.stringValue),
                    lastName: TaskNameValidator.validate(lastNameField.stringValue),
                    email: email,
                    phoneNumber: TaskNameValidator.validate(phoneField.stringValue),
                    address1: TaskNameValidator.validate(address1Field.stringValue),
                    town: TaskNameValidator.validate(townField.stringValue),
                    postcode: TaskNameValidator.validate(postcodeField.stringValue),
                    country: TaskNameValidator.validate(countryField.stringValue)
                )
                self.rebuild()
            } catch {
                self.presentAPIError(error, action: "create the client")
            }
        }
    }

    private func resolvedClientName(organisationName: String, firstName: String, lastName: String) -> String? {
        if let organisationName = TaskNameValidator.validate(organisationName) {
            return organisationName
        }
        if let firstName = TaskNameValidator.validate(firstName), let lastName = TaskNameValidator.validate(lastName) {
            return "\(firstName) \(lastName)"
        }
        return nil
    }

    private func presentAddProjectForm(clientId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.runAddProjectForm(clientId: clientId)
        }
    }

    private func runAddProjectForm(clientId: String) {
        let alert = NSAlert()
        alert.icon = Self.formIcon
        alert.messageText = "New Project"
        let createButton = alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let controlWidth: CGFloat = 180

        func makeTextField(_ initialValue: String, placeholder: String? = nil, toolTip: String) -> NSTextField {
            let field = initialValue.isEmpty ? NSTextField(frame: .zero) : NSTextField(string: initialValue)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.placeholderString = placeholder
            field.toolTip = toolTip
            field.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
            return field
        }

        func makePopup(_ titles: [String], toolTip: String) -> NSPopUpButton {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.addItems(withTitles: titles)
            popup.toolTip = toolTip
            popup.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
            return popup
        }

        let nameField = makeTextField("", placeholder: "Project name", toolTip: "The project's name, as it'll appear throughout FreeAgent.")
        let statusPopup = makePopup(ProjectStatus.allCases.map(\.rawValue), toolTip: "Whether the project is currently active, completed, cancelled, or hidden from most views.")
        let currencyPopup = makePopup(Self.freeAgentCurrencyCodes, toolTip: "The currency this project is billed in.")
        currencyPopup.selectItem(withTitle: "GBP")
        let budgetField = makeTextField("0", toolTip: "The project's budget, in the units chosen below. 0 means no budget set.")
        let budgetUnitsPopup = makePopup(BudgetUnits.allCases.map(\.rawValue), toolTip: "Whether the budget above is measured in hours, days, or a money amount.")
        let hoursPerDayField = makeTextField("8", toolTip: "How many hours count as one full day of work on this project — used to convert between hours and days.")
        let billingRateField = makeTextField("0", toolTip: "The standard rate charged per billing period (set below) for time on this project.")
        let billingPeriodPopup = makePopup(BillingPeriod.allCases.map(\.rawValue), toolTip: "Whether the billing rate above is per hour or per day.")

        let invoiceSequenceCheckbox = NSButton(checkboxWithTitle: "Uses project invoice sequence", target: nil, action: nil)
        invoiceSequenceCheckbox.state = .off
        invoiceSequenceCheckbox.toolTip = "When on, invoices for this project get their own numbering sequence instead of sharing your company's main invoice sequence."

        let poReferenceField = makeTextField("", placeholder: "PO / contract reference", toolTip: "An optional purchase order or contract reference for this project.")
        let startsOnField = makeTextField("", placeholder: "YYYY-MM-DD", toolTip: "When this project starts. Leave blank if it's ongoing/undated.")
        let endsOnField = makeTextField("", placeholder: "YYYY-MM-DD", toolTip: "When this project ends. Leave blank if it's ongoing/undated.")

        let stack = NSStackView(views: [
            labeledRow("Name *", nameField, required: true),
            labeledRow("Status *", statusPopup, required: true),
            labeledRow("Currency *", currencyPopup, required: true),
            labeledRow("Budget *", budgetField, required: true),
            labeledRow("Budget units *", budgetUnitsPopup, required: true),
            labeledRow("Hours/day *", hoursPerDayField, required: true),
            labeledRow("Billing rate *", billingRateField, required: true),
            labeledRow("Billing period *", billingPeriodPopup, required: true),
            labeledRow("PO reference", poReferenceField),
            labeledRow("Starts on", startsOnField),
            labeledRow("Ends on", endsOnField),
            invoiceSequenceCheckbox,
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        alert.accessoryView = Self.frameBasedContainer(wrapping: stack)
        alert.window.initialFirstResponder = nameField
        let observers = liveValidate(
            button: createButton,
            fields: [nameField, budgetField, hoursPerDayField, billingRateField, startsOnField, endsOnField]
        ) {
            guard TaskNameValidator.validate(nameField.stringValue) != nil else { return false }
            guard let budget = Double(budgetField.stringValue), budget >= 0 else { return false }
            guard let hoursPerDay = Double(hoursPerDayField.stringValue), hoursPerDay > 0 else { return false }
            guard let billingRate = Double(billingRateField.stringValue), billingRate >= 0 else { return false }
            guard let startsOn = Self.parseOptionalDate(startsOnField.stringValue) else { return false }
            guard let endsOn = Self.parseOptionalDate(endsOnField.stringValue) else { return false }
            if let startsOn, let endsOn, endsOn < startsOn { return false }
            return true
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        endLiveValidate(observers)
        guard response == .alertFirstButtonReturn else { return }

        guard let name = TaskNameValidator.validate(nameField.stringValue) else {
            presentValidationError("Enter a project name.")
            return
        }
        guard let status = ProjectStatus(rawValue: statusPopup.titleOfSelectedItem ?? ""),
              let budgetUnits = BudgetUnits(rawValue: budgetUnitsPopup.titleOfSelectedItem ?? ""),
              let billingPeriod = BillingPeriod(rawValue: billingPeriodPopup.titleOfSelectedItem ?? "") else {
            presentValidationError("Select a status, budget unit, and billing period.")
            return
        }
        guard let budget = Double(budgetField.stringValue), budget >= 0,
              let hoursPerDay = Double(hoursPerDayField.stringValue), hoursPerDay > 0,
              let billingRate = Double(billingRateField.stringValue), billingRate >= 0 else {
            presentValidationError("Budget and billing rate must be zero or more, and hours/day must be greater than zero.")
            return
        }
        guard let startsOn = Self.parseOptionalDate(startsOnField.stringValue) else {
            presentValidationError("\"Starts on\" must be a date in YYYY-MM-DD format, or left blank.")
            return
        }
        guard let endsOn = Self.parseOptionalDate(endsOnField.stringValue) else {
            presentValidationError("\"Ends on\" must be a date in YYYY-MM-DD format, or left blank.")
            return
        }
        if let startsOn, let endsOn, endsOn < startsOn {
            presentValidationError("\"Ends on\" can't be before \"Starts on\".")
            return
        }

        Task { @MainActor in
            do {
                _ = try await self.dataStore.addProject(
                    name: name,
                    clientId: clientId,
                    status: status,
                    currency: currencyPopup.titleOfSelectedItem ?? "GBP",
                    budget: budget,
                    budgetUnits: budgetUnits,
                    hoursPerDay: hoursPerDay,
                    normalBillingRate: billingRate,
                    billingPeriod: billingPeriod,
                    usesProjectInvoiceSequence: invoiceSequenceCheckbox.state == .on,
                    contractPoReference: TaskNameValidator.validate(poReferenceField.stringValue),
                    startsOn: startsOn,
                    endsOn: endsOn
                )
                self.rebuild()
                // Otherwise nothing shows it was made: the menu has no client to list it under.
                if !self.dataStore.clients.contains(where: { $0.id == clientId }) {
                    self.presentFormOutcome(
                        "Project Created",
                        "\u{201C}\(name)\u{201D} was created, but Ratchet no longer lists its client, so it won't appear in the menu.",
                        style: .informational
                    )
                }
            } catch {
                self.presentAPIError(error, action: "create the project")
            }
        }
    }

    /// A deliberately loose shape check (local@domain.tld), not full RFC 5322 validation —
    /// good enough to catch typos without rejecting legitimate unusual addresses.
    private static func isPlausibleEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard let dotIndex = domain.lastIndex(of: "."), domain.indices.contains(domain.index(after: dotIndex)) else { return false }
        return domain.first != "." && domain.last != "."
    }

    private static func parseOptionalDate(_ text: String) -> Date?? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        guard let date = CalendarDay.day(from: trimmed) else { return nil }
        return .some(date)
    }

    /// Icon for the New Task/Client/Project dialogs — the Dock/app-icon treatment rather than
    /// the tray glyph, since dialogs sit on the desktop rather than the menu bar and read better
    /// with the branded green tile. Replaces NSAlert's default generic icon.
    private static let formIcon: NSImage? = RatchetIcon.appTile(size: 64)

    /// Shared row width for every form: a 90pt label + 8pt spacing + 180pt control, plus a
    /// little breathing room. Used as an explicit width rather than trusting AppKit to derive
    /// it, because NSPopUpButton's natural/fitting size can come back wrong when measured
    /// before the view is attached to a real window — pinning width up front sidesteps that
    /// and leaves AppKit only needing to resolve height, which is far more reliable.
    nonisolated private static let formWidth: CGFloat = 330

    /// Wide enough for the longest label ("Billing period *", bold) without clipping its
    /// trailing asterisk.
    nonisolated private static let labelWidth: CGFloat = 120

    /// NSAlert sizes its accessory view reliably only when that view is legacy frame-based
    /// (translatesAutoresizingMaskIntoConstraints == true) — an Auto Layout-only view handed
    /// straight to `accessoryView` gets an oversized, mostly-empty panel instead. Wrapping the
    /// Auto Layout content in a plain frame-sized container (matching how the single-field
    /// "New Task" prompt is built) sidesteps that. The width is pinned explicitly rather than
    /// left to `fittingSize` — see `formWidth`'s doc comment for why.
    private static func frameBasedContainer(wrapping view: NSView, width: CGFloat = formWidth) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Wires `button.isEnabled` to `isValid`, re-checked on every keystroke in `fields`.
    /// Returns observer tokens the caller must pass to `endLiveValidate` once the modal closes.
    private func liveValidate(button: NSButton, fields: [NSTextField], isValid: @escaping () -> Bool) -> [NSObjectProtocol] {
        let update = { button.isEnabled = isValid() }
        update()
        return fields.map { field in
            NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in update() }
        }
    }

    private func endLiveValidate(_ observers: [NSObjectProtocol]) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func labeledRow(_ label: String, _ control: NSView, required: Bool = false) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        labelField.toolTip = control.toolTip
        if required {
            labelField.font = .boldSystemFont(ofSize: labelField.font?.pointSize ?? NSFont.systemFontSize)
        }
        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// FreeAgent's supported invoicing/project currencies (ISO 4217 codes), per
    /// https://dev.freeagent.com/docs/currencies.
    private static let freeAgentCurrencyCodes: [String] = [
        "GBP", "USD", "EUR", "AED", "AMD", "AOA", "ARS", "AUD", "AWG", "AZN", "BBD", "BDT", "BGN",
        "BRL", "BWP", "CAD", "CHF", "CLP", "CNY", "COP", "CRC", "CUC", "CUP", "CZK", "DKK", "DOP",
        "EGP", "FJD", "GEL", "GHS", "GTQ", "GYD", "HKD", "HNL", "HRK", "HUF", "IDR", "ILS", "INR",
        "ISK", "JMD", "JPY", "KES", "KRW", "KWD", "KYD", "KZT", "LAK", "LBP", "LKR", "LTL", "LVL",
        "MAD", "MDL", "MGA", "MUR", "MVR", "MWK", "MXN", "MYR", "MZN", "NAD", "NGN", "NOK", "NPR",
        "NZD", "OMR", "PEN", "PHP", "PKR", "PLN", "QAR", "RON", "RSD", "RUB", "RWF", "SAR", "SCR",
        "SEK", "SGD", "THB", "TND", "TRY", "TTD", "TWD", "TZS", "UAH", "UGX", "UYU", "VEF", "VND",
        "VUV", "XAF", "XCD", "XOF", "ZAR", "ZMK",
    ]

    private func presentValidationError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't create that"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private extension DataStoreError {
    /// The `logTime` outcomes that qualify an entry rather than fail it.
    var qualifiesLoggedEntry: Bool { self == .alreadyLogged || self == .unconfirmed(.timeslip) }

    var isUnconfirmed: Bool {
        if case .unconfirmed = self { return true }
        return false
    }
}
