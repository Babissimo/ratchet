// Sources/RatchetCore/StatusItemController.swift
import AppKit

public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let dataStore: DataStore
    private var elapsedTimer: Timer?
    private weak var elapsedMenuItem: NSMenuItem?

    /// Exposed for tests to inspect the live NSStatusItem's menu/icon.
    public var statusItemForTesting: NSStatusItem { statusItem }

    public init(appState: AppState, dataStore: DataStore, statusBar: NSStatusBar = .system) {
        self.appState = appState
        self.dataStore = dataStore
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        appState.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    deinit {
        elapsedTimer?.invalidate()
    }

    private lazy var actions: MenuActions = MenuActions(
        logIn: { [weak self] in self?.appState.logIn() },
        logOut: { [weak self] in self?.appState.logOut() },
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
        openFreeAgent: {
            NSWorkspace.shared.open(URL(string: "https://app.freeagent.com")!)
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

    private func presentAPIError(_ error: Error, action: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't \(action)"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

    private func updateIcon() {
        let isTracking: Bool
        if case .tracking = appState.screen { isTracking = true } else { isTracking = false }
        if isTracking {
            // Non-filled "clock" (face + hands as separate layers) rather than "clock.fill" —
            // a solid green disc read as too much color; this keeps the face white/adaptive
            // and tints only the hands green, so most of the glyph stays neutral.
            let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Ratchet")
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen])
            let coloredImage = image?.withSymbolConfiguration(config)
            // Non-template so the green survives — NSStatusItem flattens template images to
            // the menu bar's monochrome tint, which would erase the color.
            coloredImage?.isTemplate = false
            statusItem.button?.image = coloredImage
        } else {
            let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Ratchet")
            image?.isTemplate = true
            statusItem.button?.image = image
        }
    }

    private func updateTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if case .tracking(_, let startedAt) = appState.screen {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard case .tracking = self.appState.screen else { return }
                self.elapsedMenuItem?.title = ElapsedTimeFormatter.format(seconds: Date().timeIntervalSince(startedAt))
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

    /// Parses the billing rate field: blank means "inherit the project's rate" (nil),
    /// otherwise it must be a non-negative number. Returns nil (with an error shown) if invalid.
    private func parseOptionalBillingRate(_ field: NSTextField) -> Double?? {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .some(nil) }
        guard let parsed = Double(text), parsed >= 0 else {
            presentValidationError("Billing rate must be zero or more, or left blank to use the project's rate.")
            return nil
        }
        return .some(parsed)
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
        let observers = liveValidate(button: addButton, fields: [nameField]) {
            TaskNameValidator.validate(nameField.stringValue) != nil
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
            do {
                _ = try await self.dataStore.addTask(
                    name: name,
                    projectId: projectId,
                    clientId: clientId,
                    isBillable: billableCheckbox.state == .on,
                    status: status,
                    billingRate: billingRate,
                    billingPeriod: billingRate == nil ? nil : billingPeriod
                )
                self.rebuild()
            } catch {
                self.presentAPIError(error, action: "create the task")
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
        let observers = liveValidate(button: createButton, fields: [nameField, durationField]) {
            guard TaskNameValidator.validate(nameField.stringValue) != nil else { return false }
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
            labeledRow("Organisation *", orgField, required: true),
            labeledRow("First name *", firstNameField, required: true),
            labeledRow("Last name *", lastNameField, required: true),
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
        let observers = liveValidate(button: createButton, fields: [orgField, firstNameField, lastNameField]) { [self] in
            resolvedClientName(
                organisationName: orgField.stringValue,
                firstName: firstNameField.stringValue,
                lastName: lastNameField.stringValue
            ) != nil
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
        guard let name else {
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
                    name: name,
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
        guard let date = projectDateFormatter.date(from: trimmed) else { return nil }
        return .some(date)
    }

    private static let projectDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Icon for the New Task/Client/Project dialogs, matching the menu bar glyph — replaces
    /// NSAlert's default (a generic icon, since this app has no bundled app icon).
    private static let formIcon: NSImage? = NSImage(systemSymbolName: "clock", accessibilityDescription: "Ratchet")

    /// Shared row width for every form: a 90pt label + 8pt spacing + 180pt control, plus a
    /// little breathing room. Used as an explicit width rather than trusting AppKit to derive
    /// it, because NSPopUpButton's natural/fitting size can come back wrong when measured
    /// before the view is attached to a real window — pinning width up front sidesteps that
    /// and leaves AppKit only needing to resolve height, which is far more reliable.
    private static let formWidth: CGFloat = 330

    /// Wide enough for the longest label ("Billing period *", bold) without clipping its
    /// trailing asterisk.
    private static let labelWidth: CGFloat = 120

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
