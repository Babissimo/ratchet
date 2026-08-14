// Sources/RatchetCore/StatusItemController.swift
import AppKit

@MainActor
public final class StatusItemController {
    public typealias LoginHandler = () async throws -> Void

    /// Called after a login's follow-up `refresh()` succeeds, to adopt whatever timer FreeAgent
    /// says is already running. Injected because "which timeslip is running" lives on the
    /// concrete `FreeAgentDataStore`, not on the `DataStore` protocol — see
    /// `restoreRunningTimer(from:into:)` in the app target, which both this and the launch-time
    /// restore in `AppDelegate` call.
    public typealias RestoreRunningTimerHandler = () -> Void

    private let statusItem: NSStatusItem
    private let appState: AppState
    private let dataStore: DataStore
    private let performLogin: LoginHandler
    private let restoreRunningTimer: RestoreRunningTimerHandler
    private var elapsedTimer: Timer?
    private weak var elapsedMenuItem: NSMenuItem?
    private var isLoggingIn = false
    private var appearanceObservation: NSKeyValueObservation?

    /// Exposed for tests to inspect the live NSStatusItem's menu/icon.
    public var statusItemForTesting: NSStatusItem { statusItem }

    /// Invoked after a successful `appState.logOut()`, e.g. to clear stored credentials.
    public var onLogOut: (() -> Void)?

    public init(
        appState: AppState,
        dataStore: DataStore,
        statusBar: NSStatusBar = .system,
        performLogin: @escaping LoginHandler = {},
        restoreRunningTimer: @escaping RestoreRunningTimerHandler = {}
    ) {
        self.appState = appState
        self.dataStore = dataStore
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        self.performLogin = performLogin
        self.restoreRunningTimer = restoreRunningTimer
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
    }

    deinit {
        elapsedTimer?.invalidate()
        appearanceObservation?.invalidate()
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
                    self.restoreRunningTimer()
                    self.rebuild()
                } catch {
                    self.presentAPIError(error, action: "log in")
                }
            }
        },
        logOut: { [weak self] in
            self?.performLogOut()
        },
        startTracking: { [weak self] task in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let timeslip = try await self.dataStore.startTimer(
                        taskId: task.taskId, projectId: task.projectId, clientId: task.clientId
                    )
                    self.appState.startTracking(task, startedAt: timeslip.date)
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
        refresh: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.dataStore.refresh()
                    self.rebuild()
                } catch {
                    self.presentAPIError(error, action: "refresh")
                }
            }
        },
        toggleLaunchAtLogin: { [weak self] in
            guard let self else { return }
            self.appState.setLaunchAtLogin(!self.appState.launchAtLoginEnabled)
        },
        openFreeAgent: { [weak self] in
            let url = self?.dataStore.webAppURL ?? URL(string: "https://app.freeagent.com")!
            NSWorkspace.shared.open(url)
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
        quit: {
            NSApp.terminate(nil)
        }
    )

    /// Drops local session state and clears stored credentials via `onLogOut`. The single place
    /// "log out" happens, so the menu-driven Log Out and the forced logout below can't diverge.
    private func performLogOut() {
        appState.logOut()
        onLogOut?()
    }

    /// Forces a logout after the session turned out to be dead, then tells the user once.
    /// Exposed so `AppDelegate`'s launch-time restore can route an `.unauthorized` here rather
    /// than swallowing it and leaving a logged-in-looking, permanently empty menu.
    public func handleSessionExpired() {
        performLogOut()
        rebuild()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Signed out of FreeAgent"
        alert.informativeText = "Your FreeAgent session has expired, so Ratchet signed you out. Choose \"Log in with browser\" to reconnect."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't \(action)"
        alert.informativeText = "\(error)"
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
        let menu = MenuBuilder.build(state: appState, dataStore: dataStore, actions: actions)
        statusItem.menu = menu
        if case .tracking = appState.screen {
            // Index 0 is the disabled elapsed-time line built by MenuBuilder.buildTracking.
            elapsedMenuItem = menu.items[0]
        } else {
            elapsedMenuItem = nil
        }
        updateIcon()
        updateTimer()
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

    private func updateTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if case .tracking(_, let startedAt) = appState.screen {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                // Scheduled on RunLoop.main below, so this always fires on the main thread;
                // `assumeIsolated` tells the compiler what the runtime already guarantees.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard case .tracking = self.appState.screen else { return }
                    self.elapsedMenuItem?.title = ElapsedTimeFormatter.format(seconds: Date().timeIntervalSince(startedAt))
                }
            }
            // Menus run the run loop in .eventTracking mode while open (the only time the
            // elapsed line is visible), so .common is required for the tick to fire then.
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
        }
    }

    private func presentAddTaskPrompt(clientId: String, projectId: String) {
        // Defer until the menu-tracking run loop session has unwound: running a modal
        // session synchronously from inside menu action dispatch is a known AppKit hazard
        // (the alert can appear behind/non-key, or interact oddly with the just-closed menu).
        DispatchQueue.main.async { [weak self] in
            self?.runAddTaskPrompt(clientId: clientId, projectId: projectId)
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

    private func runAddTaskPrompt(clientId: String, projectId: String) {
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
            } catch {
                self.presentAPIError(error, action: "create the task")
                return
            }
            self.rebuild()

            // "New task…" is only reachable from the Start > drill-down, so creating one here
            // means the user wants to start tracking it immediately — not just add it. The task
            // itself is already created at this point, so a failure here gets its own message
            // rather than implying the task creation failed too.
            guard let client = self.dataStore.clients.first(where: { $0.id == clientId }),
                  let project = client.projects.first(where: { $0.id == projectId })
            else { return }
            do {
                let timeslip = try await self.dataStore.startTimer(taskId: task.id, projectId: projectId, clientId: clientId)
                let ref = TrackedTaskRef(
                    clientId: client.id, clientName: client.name,
                    projectId: project.id, projectName: project.name,
                    taskId: task.id, taskName: task.name
                )
                self.appState.startTracking(ref, startedAt: timeslip.date)
            } catch {
                self.presentAPIError(error, action: "start tracking the new task")
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

                let taskName = self.dataStore.clients.first(where: { $0.id == clientId })?
                    .projects.first(where: { $0.id == projectId })?
                    .tasks.first(where: { $0.id == taskId })?
                    .name ?? "the task"
                self.presentLoggedConfirmation(taskName: taskName, hours: hours, date: datePicker.dateValue)
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
            do {
                let newTask = try await self.dataStore.addTask(
                    name: name,
                    projectId: projectId,
                    clientId: clientId,
                    isBillable: billableCheckbox.state == .on,
                    status: status,
                    billingRate: billingRate,
                    billingPeriod: billingRate == nil ? nil : billingPeriod
                )
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
            } catch {
                self.presentAPIError(error, action: "create the task and log time")
            }
        }
    }

    private func presentLoggedConfirmation(taskName: String, hours: Double, date: Date) {
        let duration = ElapsedTimeFormatter.format(seconds: hours * 3600)
        let dateText = Self.confirmationDateFormatter.string(from: date)
        let alert = NSAlert()
        alert.icon = Self.formIcon
        alert.messageText = "Time Logged"
        alert.informativeText = "\(duration) logged for \(taskName) on \(dateText)."
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
