# Ratchet Menu Bar UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Ratchet menu bar UI — the `NSStatusItem`/`NSMenu` tree, its four screens, and the drill-down/settings submenus — driven entirely by an in-memory fake data store, with no networking, auth, or persistence.

**Architecture:** A Swift Package with two targets. `RatchetCore` is a library holding everything: data models, a fake data store, the `AppState` state machine, pure formatting/validation helpers, and the AppKit menu-building code (`MenuBuilder`, `StatusItemController`). `Ratchet` is a thin executable that boots `NSApplication` as an accessory (no dock icon) and hands off to `RatchetCore`. Keeping the logic in the library target — including the AppKit pieces — makes it reachable from `RatchetCoreTests` via `@testable import`, so the menu tree can be asserted on directly (titles, enabled state, submenus) without needing the app to actually run.

**Tech Stack:** Swift 5.9+, Swift Package Manager, AppKit (`NSStatusItem`, `NSMenu`, `NSAlert`), XCTest. No SwiftUI, no Xcode project file — everything builds via `swift build` / `swift test` / `swift run`.

## Global Constraints

- Target macOS 13+ (spec: "Swift + SwiftUI/AppKit, macOS 13+").
- No dock icon: app runs as an accessory app (`NSApp.setActivationPolicy(.accessory)`), not via an `Info.plist` `LSUIElement` key — no bundle is being produced in this phase.
- No networking, no OAuth, no persistence beyond `UserDefaults` for the `Launch at login` checkbox state (the real `SMAppService` wiring is future work, per spec's non-goals).
- Menu bar icon: SF Symbol only, tinted/filled (`clock.fill`) when tracking, outline (`clock`) when idle — no text or elapsed time in the icon itself.
- All menu item copy must match the spec's exact strings: "Log in with browser", "Start tracking {task}", "Start", "Settings", "Quit", "Stop tracking", "Refresh projects & tasks", "Launch at login", "Open FreeAgent", "Log out", "New task…".
- No "Today: N h M m" line, no separate "Resume tracking" label, no client/project creation from the menu — all explicitly out of scope per the spec's "Considered and dropped" / "Future additions" sections.
- Every task in this plan ends with `swift build` and (where applicable) `swift test` both passing before commit.

---

### Task 1: Package scaffolding and a status item with a static icon

**Files:**
- Create: `Package.swift`
- Create: `Sources/Ratchet/main.swift`
- Create: `Sources/Ratchet/AppDelegate.swift`
- Create: `Sources/RatchetCore/PlaceholderStatusItem.swift` (temporary, replaced in Task 9 — see note in Step 3)

**Interfaces:**
- Produces: a running `swift run` shows a menu bar icon with no dock icon. No public API consumed by later tasks except the target/package layout itself.

This task has no unit tests — it's pure bootstrapping. Verification is a manual build-and-run check.

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ratchet",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RatchetCore"),
        .executableTarget(name: "Ratchet", dependencies: ["RatchetCore"]),
        .testTarget(name: "RatchetCoreTests", dependencies: ["RatchetCore"]),
    ]
)
```

- [ ] **Step 2: Create a minimal status item so there's something to see**

```swift
// Sources/RatchetCore/PlaceholderStatusItem.swift
import AppKit

public final class PlaceholderStatusItem {
    private let statusItem: NSStatusItem

    public init(statusBar: NSStatusBar = .system) {
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Ratchet")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}
```

- [ ] **Step 3: Wire up the executable**

```swift
// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: PlaceholderStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = PlaceholderStatusItem()
    }
}
```

```swift
// Sources/Ratchet/main.swift
import AppKit

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: Build and run manually**

Run: `swift build`
Expected: builds with no errors.

Run: `swift run Ratchet` (then check the menu bar, then quit via the menu's Quit item)
Expected: a clock icon appears in the menu bar with no dock icon or app window; clicking it shows a "Quit" item that quits the app.

Note: `PlaceholderStatusItem` is deleted and replaced by the real `StatusItemController` in Task 9 — it exists only so this task has an independently verifiable deliverable.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources
git commit -m "chore: scaffold Ratchet menu bar app package"
```

---

### Task 2: Core data models and the fake data store

**Files:**
- Create: `Sources/RatchetCore/Models.swift`
- Create: `Sources/RatchetCore/DataStore.swift`
- Create: `Sources/RatchetCore/FakeDataStore.swift`
- Test: `Tests/RatchetCoreTests/FakeDataStoreTests.swift`

**Interfaces:**
- Produces: `RatchetTask { id, name }`, `RatchetProject { id, name, tasks }`, `RatchetClient { id, name, projects }`, `TrackedTaskRef { clientId, clientName, projectId, projectName, taskId, taskName }`, `protocol DataStore { clients, accountEmail, addTask(name:projectId:clientId:) -> RatchetTask?, refresh() }`, `FakeDataStore.seeded() -> FakeDataStore`.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing test for the fake store's seed data and lookups**

```swift
// Tests/RatchetCoreTests/FakeDataStoreTests.swift
import XCTest
@testable import RatchetCore

final class FakeDataStoreTests: XCTestCase {
    func test_seeded_hasExpectedClientsAndAccountEmail() {
        let store = FakeDataStore.seeded()
        XCTAssertEqual(store.accountEmail, "al@example.com")
        XCTAssertEqual(store.clients.map(\.name), ["Acme", "Other Co"])
        XCTAssertEqual(store.clients[0].projects.map(\.name), ["Website Redesign", "Q3 Retainer"])
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development", "Design"])
    }

    func test_addTask_appendsToMatchingProjectAndReturnsIt() {
        let store = FakeDataStore.seeded()
        let clientId = store.clients[0].id
        let projectId = store.clients[0].projects[0].id

        let created = store.addTask(name: "QA", projectId: projectId, clientId: clientId)

        XCTAssertEqual(created?.name, "QA")
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development", "Design", "QA"])
    }

    func test_addTask_returnsNilForUnknownProject() {
        let store = FakeDataStore.seeded()
        let result = store.addTask(name: "QA", projectId: "nonexistent", clientId: store.clients[0].id)
        XCTAssertNil(result)
    }

    func test_refresh_incrementsRefreshCount() {
        let store = FakeDataStore.seeded()
        XCTAssertEqual(store.refreshCount, 0)
        store.refresh()
        XCTAssertEqual(store.refreshCount, 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FakeDataStoreTests`
Expected: FAIL — `FakeDataStore` does not exist yet (compile error).

- [ ] **Step 3: Write the models**

```swift
// Sources/RatchetCore/Models.swift
import Foundation

public struct RatchetTask: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RatchetProject: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let tasks: [RatchetTask]

    public init(id: String, name: String, tasks: [RatchetTask]) {
        self.id = id
        self.name = name
        self.tasks = tasks
    }
}

public struct RatchetClient: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let projects: [RatchetProject]

    public init(id: String, name: String, projects: [RatchetProject]) {
        self.id = id
        self.name = name
        self.projects = projects
    }
}

public struct TrackedTaskRef: Equatable, Codable {
    public let clientId: String
    public let clientName: String
    public let projectId: String
    public let projectName: String
    public let taskId: String
    public let taskName: String

    public init(clientId: String, clientName: String, projectId: String, projectName: String, taskId: String, taskName: String) {
        self.clientId = clientId
        self.clientName = clientName
        self.projectId = projectId
        self.projectName = projectName
        self.taskId = taskId
        self.taskName = taskName
    }
}
```

- [ ] **Step 4: Write the DataStore protocol**

```swift
// Sources/RatchetCore/DataStore.swift
public protocol DataStore: AnyObject {
    var clients: [RatchetClient] { get }
    var accountEmail: String { get }
    var refreshCount: Int { get }
    func addTask(name: String, projectId: String, clientId: String) -> RatchetTask?
    func refresh()
}
```

- [ ] **Step 5: Write the fake implementation**

```swift
// Sources/RatchetCore/FakeDataStore.swift
import Foundation

public final class FakeDataStore: DataStore {
    public private(set) var clients: [RatchetClient]
    public let accountEmail: String
    public private(set) var refreshCount = 0

    public init(clients: [RatchetClient], accountEmail: String) {
        self.clients = clients
        self.accountEmail = accountEmail
    }

    public static func seeded() -> FakeDataStore {
        let developmentTask = RatchetTask(id: "task-1", name: "Development")
        let designTask = RatchetTask(id: "task-2", name: "Design")
        let websiteProject = RatchetProject(id: "proj-1", name: "Website Redesign", tasks: [developmentTask, designTask])
        let copywritingTask = RatchetTask(id: "task-3", name: "Copywriting")
        let retainerProject = RatchetProject(id: "proj-2", name: "Q3 Retainer", tasks: [copywritingTask])
        let acme = RatchetClient(id: "client-1", name: "Acme", projects: [websiteProject, retainerProject])
        let otherCo = RatchetClient(id: "client-2", name: "Other Co", projects: [])
        return FakeDataStore(clients: [acme, otherCo], accountEmail: "al@example.com")
    }

    public func addTask(name: String, projectId: String, clientId: String) -> RatchetTask? {
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { return nil }
        guard let projectIndex = clients[clientIndex].projects.firstIndex(where: { $0.id == projectId }) else { return nil }

        let newTask = RatchetTask(id: "task-\(UUID().uuidString.prefix(8))", name: name)
        var projects = clients[clientIndex].projects
        let existingProject = projects[projectIndex]
        projects[projectIndex] = RatchetProject(id: existingProject.id, name: existingProject.name, tasks: existingProject.tasks + [newTask])
        clients[clientIndex] = RatchetClient(id: clients[clientIndex].id, name: clients[clientIndex].name, projects: projects)
        return newTask
    }

    public func refresh() {
        refreshCount += 1
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter FakeDataStoreTests`
Expected: PASS (4 tests)

- [ ] **Step 7: Commit**

```bash
git add Sources/RatchetCore/Models.swift Sources/RatchetCore/DataStore.swift Sources/RatchetCore/FakeDataStore.swift Tests/RatchetCoreTests/FakeDataStoreTests.swift
git commit -m "feat: add core models and fake data store"
```

---

### Task 3: AppState state machine

**Files:**
- Create: `Sources/RatchetCore/AppState.swift`
- Test: `Tests/RatchetCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `TrackedTaskRef` (Task 2).
- Produces: `enum Screen { loggedOut, idleNoHistory, idle(mostRecent: TrackedTaskRef), tracking(task: TrackedTaskRef, startedAt: Date) }`, `class AppState { screen: Screen (computed), launchAtLoginEnabled: Bool, onChange: (() -> Void)?, init(clock:), logIn(), logOut(), startTracking(_:), stopTracking(), setLaunchAtLogin(_:) }`. Later tasks (5–9) read `appState.screen` and call these methods.

- [ ] **Step 1: Write the failing tests for every state transition**

```swift
// Tests/RatchetCoreTests/AppStateTests.swift
import XCTest
@testable import RatchetCore

final class AppStateTests: XCTestCase {
    private let sampleTask = TrackedTaskRef(
        clientId: "client-1", clientName: "Acme",
        projectId: "proj-1", projectName: "Website Redesign",
        taskId: "task-1", taskName: "Development"
    )

    func test_initialScreen_isLoggedOut() {
        let state = AppState()
        XCTAssertEqual(state.screen, .loggedOut)
    }

    func test_logIn_withNoHistory_showsIdleNoHistory() {
        let state = AppState()
        state.logIn()
        XCTAssertEqual(state.screen, .idleNoHistory)
    }

    func test_startTracking_thenStop_returnsToIdleWithMostRecent() {
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        let state = AppState(clock: { fixedDate })
        state.logIn()

        state.startTracking(sampleTask)
        XCTAssertEqual(state.screen, .tracking(task: sampleTask, startedAt: fixedDate))

        state.stopTracking()
        XCTAssertEqual(state.screen, .idle(mostRecent: sampleTask))
    }

    func test_startTracking_afterAlreadyHavingHistory_offersSameMostRecentOnRestart() {
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)
        state.stopTracking()

        state.startTracking(sampleTask)
        XCTAssertEqual(state.screen, .tracking(task: sampleTask, startedAt: state.trackingStartedAtForTesting!))
    }

    func test_logOut_resetsToLoggedOutAndClearsHistory() {
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)
        state.stopTracking()

        state.logOut()
        XCTAssertEqual(state.screen, .loggedOut)

        state.logIn()
        XCTAssertEqual(state.screen, .idleNoHistory)
    }

    func test_onChange_isCalledOnEveryTransition() {
        let state = AppState()
        var changeCount = 0
        state.onChange = { changeCount += 1 }

        state.logIn()
        state.startTracking(sampleTask)
        state.stopTracking()
        state.logOut()

        XCTAssertEqual(changeCount, 4)
    }

    func test_setLaunchAtLogin_updatesFlagAndFiresOnChange() {
        let state = AppState()
        XCTAssertFalse(state.launchAtLoginEnabled)

        var changed = false
        state.onChange = { changed = true }
        state.setLaunchAtLogin(true)

        XCTAssertTrue(state.launchAtLoginEnabled)
        XCTAssertTrue(changed)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AppStateTests`
Expected: FAIL — `AppState` and `Screen` do not exist yet (compile error).

- [ ] **Step 3: Write AppState**

```swift
// Sources/RatchetCore/AppState.swift
import Foundation

public enum Screen: Equatable {
    case loggedOut
    case idleNoHistory
    case idle(mostRecent: TrackedTaskRef)
    case tracking(task: TrackedTaskRef, startedAt: Date)
}

public final class AppState {
    public private(set) var isLoggedIn: Bool = false
    public private(set) var mostRecent: TrackedTaskRef?
    public private(set) var trackingTask: TrackedTaskRef?
    public private(set) var trackingStartedAt: Date?
    public private(set) var launchAtLoginEnabled: Bool = false
    public var onChange: (() -> Void)?

    private let clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Exposed for tests that need the exact instant a running timer started.
    public var trackingStartedAtForTesting: Date? { trackingStartedAt }

    public var screen: Screen {
        guard isLoggedIn else { return .loggedOut }
        if let task = trackingTask, let startedAt = trackingStartedAt {
            return .tracking(task: task, startedAt: startedAt)
        }
        if let mostRecent {
            return .idle(mostRecent: mostRecent)
        }
        return .idleNoHistory
    }

    public func logIn() {
        isLoggedIn = true
        onChange?()
    }

    public func logOut() {
        isLoggedIn = false
        mostRecent = nil
        trackingTask = nil
        trackingStartedAt = nil
        onChange?()
    }

    public func startTracking(_ task: TrackedTaskRef) {
        trackingTask = task
        trackingStartedAt = clock()
        mostRecent = task
        onChange?()
    }

    public func stopTracking() {
        trackingTask = nil
        trackingStartedAt = nil
        onChange?()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginEnabled = enabled
        onChange?()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter AppStateTests`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/RatchetCore/AppState.swift Tests/RatchetCoreTests/AppStateTests.swift
git commit -m "feat: add AppState screen state machine"
```

---

### Task 4: Elapsed time formatting and task name validation

**Files:**
- Create: `Sources/RatchetCore/ElapsedTimeFormatter.swift`
- Create: `Sources/RatchetCore/TaskNameValidator.swift`
- Test: `Tests/RatchetCoreTests/ElapsedTimeFormatterTests.swift`
- Test: `Tests/RatchetCoreTests/TaskNameValidatorTests.swift`

**Interfaces:**
- Produces: `ElapsedTimeFormatter.format(seconds: TimeInterval) -> String` (used by Task 6's tracking screen), `TaskNameValidator.validate(_ rawInput: String) -> String?` (used by Task 9's new-task prompt).

- [ ] **Step 1: Write the failing formatter test**

```swift
// Tests/RatchetCoreTests/ElapsedTimeFormatterTests.swift
import XCTest
@testable import RatchetCore

final class ElapsedTimeFormatterTests: XCTestCase {
    func test_zeroSeconds_formatsAsZeroZero() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 0), "0:00")
    }

    func test_ninetySeconds_formatsAsOneMinute() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 90), "0:01")
    }

    func test_sixThousandFourHundredTwentySeconds_formatsAsOneFortySeven() {
        // 1 hour 47 minutes, matching the spec's tracking screen example
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 6420), "1:47")
    }

    func test_negativeSeconds_clampsToZero() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: -5), "0:00")
    }
}
```

- [ ] **Step 2: Write the failing validator test**

```swift
// Tests/RatchetCoreTests/TaskNameValidatorTests.swift
import XCTest
@testable import RatchetCore

final class TaskNameValidatorTests: XCTestCase {
    func test_emptyString_isInvalid() {
        XCTAssertNil(TaskNameValidator.validate(""))
    }

    func test_whitespaceOnly_isInvalid() {
        XCTAssertNil(TaskNameValidator.validate("   \n  "))
    }

    func test_trimsSurroundingWhitespace() {
        XCTAssertEqual(TaskNameValidator.validate("  Design  "), "Design")
    }

    func test_validName_isReturnedUnchanged() {
        XCTAssertEqual(TaskNameValidator.validate("QA"), "QA")
    }
}
```

- [ ] **Step 3: Run both to verify they fail**

Run: `swift test --filter "ElapsedTimeFormatterTests|TaskNameValidatorTests"`
Expected: FAIL — neither type exists yet (compile error).

- [ ] **Step 4: Implement the formatter**

```swift
// Sources/RatchetCore/ElapsedTimeFormatter.swift
import Foundation

public enum ElapsedTimeFormatter {
    public static func format(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }
}
```

- [ ] **Step 5: Implement the validator**

```swift
// Sources/RatchetCore/TaskNameValidator.swift
import Foundation

public enum TaskNameValidator {
    public static func validate(_ rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "ElapsedTimeFormatterTests|TaskNameValidatorTests"`
Expected: PASS (8 tests)

- [ ] **Step 7: Commit**

```bash
git add Sources/RatchetCore/ElapsedTimeFormatter.swift Sources/RatchetCore/TaskNameValidator.swift Tests/RatchetCoreTests/ElapsedTimeFormatterTests.swift Tests/RatchetCoreTests/TaskNameValidatorTests.swift
git commit -m "feat: add elapsed time formatter and task name validator"
```

---

### Task 5: MenuActions, ClosureMenuItem, and the logged-out / no-history menus

**Files:**
- Create: `Sources/RatchetCore/MenuActions.swift`
- Create: `Sources/RatchetCore/ClosureMenuItem.swift`
- Create: `Sources/RatchetCore/MenuBuilder.swift`
- Test: `Tests/RatchetCoreTests/MenuBuilderLoggedOutAndIdleNoHistoryTests.swift`

**Interfaces:**
- Consumes: `AppState`, `Screen` (Task 3), `DataStore` (Task 2).
- Produces: `struct MenuActions { logIn, logOut, startTracking, stopTracking, refresh, toggleLaunchAtLogin, openFreeAgent, addTask, quit }` (all closures — consumed by Tasks 6–9), `class ClosureMenuItem: NSMenuItem` (reused by Tasks 6–8), `enum MenuBuilder { static func build(state: AppState, dataStore: DataStore, actions: MenuActions) -> NSMenu }` — Task 5 implements only the `.loggedOut` and `.idleNoHistory` branches; Tasks 6–8 fill in the rest of the same file.

- [ ] **Step 1: Write the failing tests for the two simplest screens**

```swift
// Tests/RatchetCoreTests/MenuBuilderLoggedOutAndIdleNoHistoryTests.swift
import XCTest
import AppKit
@testable import RatchetCore

final class MenuBuilderLoggedOutAndIdleNoHistoryTests: XCTestCase {
    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
    }

    func test_loggedOut_showsLogInThenSeparatorThenQuit() {
        let state = AppState()
        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), ["Log in with browser", "", "Quit"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
    }

    func test_loggedOut_logInItemInvokesLogInAction() {
        var loggedIn = false
        let actions = MenuActions(
            logIn: { loggedIn = true }, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
        let menu = MenuBuilder.build(state: AppState(), dataStore: FakeDataStore.seeded(), actions: actions)

        let logInItem = menu.items[0] as! ClosureMenuItem
        _ = logInItem.target?.perform(logInItem.action, with: logInItem)

        XCTAssertTrue(loggedIn)
    }

    func test_idleNoHistory_showsOnlyStartAndFooter() {
        let state = AppState()
        state.logIn()
        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), ["Start", "", "Settings", "Quit"])
        XCTAssertNotNil(menu.items[0].submenu)
        XCTAssertNotNil(menu.items[2].submenu)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MenuBuilderLoggedOutAndIdleNoHistoryTests`
Expected: FAIL — `MenuActions`, `MenuBuilder`, `ClosureMenuItem` don't exist yet (compile error).

- [ ] **Step 3: Write MenuActions**

```swift
// Sources/RatchetCore/MenuActions.swift
public struct MenuActions {
    public let logIn: () -> Void
    public let logOut: () -> Void
    public let startTracking: (TrackedTaskRef) -> Void
    public let stopTracking: () -> Void
    public let refresh: () -> Void
    public let toggleLaunchAtLogin: () -> Void
    public let openFreeAgent: () -> Void
    public let addTask: (_ clientId: String, _ projectId: String) -> Void
    public let quit: () -> Void

    public init(
        logIn: @escaping () -> Void,
        logOut: @escaping () -> Void,
        startTracking: @escaping (TrackedTaskRef) -> Void,
        stopTracking: @escaping () -> Void,
        refresh: @escaping () -> Void,
        toggleLaunchAtLogin: @escaping () -> Void,
        openFreeAgent: @escaping () -> Void,
        addTask: @escaping (_ clientId: String, _ projectId: String) -> Void,
        quit: @escaping () -> Void
    ) {
        self.logIn = logIn
        self.logOut = logOut
        self.startTracking = startTracking
        self.stopTracking = stopTracking
        self.refresh = refresh
        self.toggleLaunchAtLogin = toggleLaunchAtLogin
        self.openFreeAgent = openFreeAgent
        self.addTask = addTask
        self.quit = quit
    }
}
```

- [ ] **Step 4: Write ClosureMenuItem**

```swift
// Sources/RatchetCore/ClosureMenuItem.swift
import AppKit

public final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    public init(title: String, handler: @escaping () -> Void, keyEquivalent: String = "") {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}
```

- [ ] **Step 5: Write MenuBuilder with the logged-out and no-history branches**

```swift
// Sources/RatchetCore/MenuBuilder.swift
import AppKit

public enum MenuBuilder {
    public static func build(state: AppState, dataStore: DataStore, actions: MenuActions) -> NSMenu {
        switch state.screen {
        case .loggedOut:
            return buildLoggedOut(actions: actions)
        case .idleNoHistory:
            return buildIdle(mostRecent: nil, dataStore: dataStore, state: state, actions: actions)
        case .idle(let mostRecent):
            return buildIdle(mostRecent: mostRecent, dataStore: dataStore, state: state, actions: actions)
        case .tracking(let task, let startedAt):
            return buildTracking(task: task, startedAt: startedAt, dataStore: dataStore, state: state, actions: actions)
        }
    }

    private static func buildLoggedOut(actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Log in with browser", handler: actions.logIn))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }

    static func buildIdle(mostRecent: TrackedTaskRef?, dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        if let mostRecent {
            menu.addItem(ClosureMenuItem(title: "Start tracking \(mostRecent.taskName)", handler: { actions.startTracking(mostRecent) }))
            menu.addItem(disabledItem("\(mostRecent.clientName) · \(mostRecent.projectName)"))
        }
        let startItem = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        startItem.submenu = buildStartSubmenu(dataStore: dataStore, actions: actions)
        menu.addItem(startItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu(dataStore: dataStore, state: state, actions: actions)
        menu.addItem(settingsItem)
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }

    static func buildTracking(task: TrackedTaskRef, startedAt: Date, dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        // Implemented in Task 6.
        NSMenu()
    }

    static func buildStartSubmenu(dataStore: DataStore, actions: MenuActions) -> NSMenu {
        // Implemented in Task 7.
        NSMenu()
    }

    static func buildSettingsSubmenu(dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        // Implemented in Task 8.
        NSMenu()
    }

    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter MenuBuilderLoggedOutAndIdleNoHistoryTests`
Expected: PASS (3 tests)

- [ ] **Step 7: Commit**

```bash
git add Sources/RatchetCore/MenuActions.swift Sources/RatchetCore/ClosureMenuItem.swift Sources/RatchetCore/MenuBuilder.swift Tests/RatchetCoreTests/MenuBuilderLoggedOutAndIdleNoHistoryTests.swift
git commit -m "feat: add MenuBuilder logged-out and no-history screens"
```

---

### Task 6: MenuBuilder idle-with-history and tracking screens

**Files:**
- Modify: `Sources/RatchetCore/MenuBuilder.swift` (fill in `buildTracking`, verify `buildIdle`'s history branch)
- Test: `Tests/RatchetCoreTests/MenuBuilderIdleWithHistoryAndTrackingTests.swift`

**Interfaces:**
- Consumes: `ElapsedTimeFormatter.format(seconds:)` (Task 4), everything from Task 5.
- Produces: nothing new for later tasks — `buildTracking` and the history branch of `buildIdle` were already referenced by `MenuBuilder.build` in Task 5's `switch`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RatchetCoreTests/MenuBuilderIdleWithHistoryAndTrackingTests.swift
import XCTest
import AppKit
@testable import RatchetCore

final class MenuBuilderIdleWithHistoryAndTrackingTests: XCTestCase {
    private let sampleTask = TrackedTaskRef(
        clientId: "client-1", clientName: "Acme",
        projectId: "proj-1", projectName: "Website Redesign",
        taskId: "task-1", taskName: "Development"
    )

    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
    }

    func test_idleWithHistory_showsStartTrackingHeaderAndSubtitle() {
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)
        state.stopTracking()

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), [
            "Start tracking Development",
            "Acme · Website Redesign",
            "Start", "", "Settings", "Quit",
        ])
        XCTAssertFalse(menu.items[1].isEnabled)
    }

    func test_idleWithHistory_topItemStartsTrackingTheMostRecentTask() {
        var started: TrackedTaskRef?
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { started = $0 }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)
        state.stopTracking()

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: actions)
        let topItem = menu.items[0] as! ClosureMenuItem
        _ = topItem.target?.perform(topItem.action, with: topItem)

        XCTAssertEqual(started, sampleTask)
    }

    func test_tracking_showsTaskSubtitleElapsedAndStop() {
        let fixedStart = Date(timeIntervalSince1970: 0)
        let state = AppState(clock: { fixedStart })
        state.logIn()
        state.startTracking(sampleTask)

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: noopActions())

        XCTAssertEqual(menu.items[0].title, "Development")
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(menu.items[1].title, "Acme · Website Redesign")
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertFalse(menu.items[2].isEnabled) // elapsed time line
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertEqual(menu.items[4].title, "Stop tracking")
        XCTAssertTrue(menu.items[5].isSeparatorItem)
        XCTAssertEqual(menu.items[6].title, "Settings")
        XCTAssertEqual(menu.items[7].title, "Quit")
    }

    func test_tracking_stopItemInvokesStopTracking() {
        var stopped = false
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: { stopped = true },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)

        let menu = MenuBuilder.build(state: state, dataStore: FakeDataStore.seeded(), actions: actions)
        let stopItem = menu.items[4] as! ClosureMenuItem
        _ = stopItem.target?.perform(stopItem.action, with: stopItem)

        XCTAssertTrue(stopped)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MenuBuilderIdleWithHistoryAndTrackingTests`
Expected: FAIL on the tracking tests — `buildTracking` currently returns an empty `NSMenu()`. The idle-with-history tests should already pass since Task 5 implemented that branch; if they don't, note the discrepancy before proceeding.

- [ ] **Step 3: Implement buildTracking**

Replace the stub `buildTracking` in `Sources/RatchetCore/MenuBuilder.swift`:

```swift
    static func buildTracking(task: TrackedTaskRef, startedAt: Date, dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledItem(task.taskName))
        menu.addItem(disabledItem("\(task.clientName) · \(task.projectName)"))
        let elapsed = ElapsedTimeFormatter.format(seconds: Date().timeIntervalSince(startedAt))
        menu.addItem(disabledItem(elapsed))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Stop tracking", handler: actions.stopTracking))
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu(dataStore: dataStore, state: state, actions: actions)
        menu.addItem(settingsItem)
        menu.addItem(ClosureMenuItem(title: "Quit", handler: actions.quit, keyEquivalent: "q"))
        return menu
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MenuBuilderIdleWithHistoryAndTrackingTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/RatchetCore/MenuBuilder.swift Tests/RatchetCoreTests/MenuBuilderIdleWithHistoryAndTrackingTests.swift
git commit -m "feat: add MenuBuilder tracking screen"
```

---

### Task 7: Start submenu — client/project/task drill-down and New task…

**Files:**
- Modify: `Sources/RatchetCore/MenuBuilder.swift` (fill in `buildStartSubmenu`, add `buildProjectsSubmenu`, `buildTasksSubmenu`)
- Test: `Tests/RatchetCoreTests/MenuBuilderStartSubmenuTests.swift`

**Interfaces:**
- Consumes: `RatchetClient`/`RatchetProject`/`RatchetTask` (Task 2), `MenuActions.startTracking`/`.addTask` (Task 5).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RatchetCoreTests/MenuBuilderStartSubmenuTests.swift
import XCTest
import AppKit
@testable import RatchetCore

final class MenuBuilderStartSubmenuTests: XCTestCase {
    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
    }

    func test_clientsLevel_listsClientsWithSubmenus() {
        let menu = MenuBuilder.buildStartSubmenu(dataStore: FakeDataStore.seeded(), actions: noopActions())
        XCTAssertEqual(menu.items.map(\.title), ["Acme", "Other Co"])
        XCTAssertNotNil(menu.items[0].submenu)
    }

    func test_projectsLevel_listsProjectsWithSubmenus() {
        let store = FakeDataStore.seeded()
        let acme = store.clients[0]
        let menu = MenuBuilder.buildStartSubmenu(dataStore: store, actions: noopActions())
        let projectsMenu = menu.items[0].submenu!

        XCTAssertEqual(projectsMenu.items.map(\.title), acme.projects.map(\.name))
        XCTAssertNotNil(projectsMenu.items[0].submenu)
    }

    func test_tasksLevel_listsTasksThenSeparatorThenNewTask() {
        let store = FakeDataStore.seeded()
        let menu = MenuBuilder.buildStartSubmenu(dataStore: store, actions: noopActions())
        let projectsMenu = menu.items[0].submenu!
        let tasksMenu = projectsMenu.items[0].submenu!

        XCTAssertEqual(tasksMenu.items.map(\.title), ["Development", "Design", "", "New task…"])
        XCTAssertTrue(tasksMenu.items[2].isSeparatorItem)
    }

    func test_clickingTask_startsTrackingWithFullRef() {
        var started: TrackedTaskRef?
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { started = $0 }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
        let store = FakeDataStore.seeded()
        let menu = MenuBuilder.buildStartSubmenu(dataStore: store, actions: actions)
        let tasksMenu = menu.items[0].submenu!.items[0].submenu!
        let developmentItem = tasksMenu.items[0] as! ClosureMenuItem

        _ = developmentItem.target?.perform(developmentItem.action, with: developmentItem)

        XCTAssertEqual(started, TrackedTaskRef(
            clientId: "client-1", clientName: "Acme",
            projectId: "proj-1", projectName: "Website Redesign",
            taskId: "task-1", taskName: "Development"
        ))
    }

    func test_clickingNewTask_invokesAddTaskWithClientAndProjectIds() {
        var addedClientId: String?
        var addedProjectId: String?
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { clientId, projectId in addedClientId = clientId; addedProjectId = projectId },
            quit: {}
        )
        let store = FakeDataStore.seeded()
        let menu = MenuBuilder.buildStartSubmenu(dataStore: store, actions: actions)
        let tasksMenu = menu.items[0].submenu!.items[0].submenu!
        let newTaskItem = tasksMenu.items[3] as! ClosureMenuItem

        _ = newTaskItem.target?.perform(newTaskItem.action, with: newTaskItem)

        XCTAssertEqual(addedClientId, "client-1")
        XCTAssertEqual(addedProjectId, "proj-1")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MenuBuilderStartSubmenuTests`
Expected: FAIL — `buildStartSubmenu` currently returns an empty `NSMenu()`.

- [ ] **Step 3: Implement the drill-down**

Replace the stub `buildStartSubmenu` in `Sources/RatchetCore/MenuBuilder.swift` and add two private helpers:

```swift
    static func buildStartSubmenu(dataStore: DataStore, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        for client in dataStore.clients {
            let item = NSMenuItem(title: client.name, action: nil, keyEquivalent: "")
            item.submenu = buildProjectsSubmenu(client: client, actions: actions)
            menu.addItem(item)
        }
        return menu
    }

    private static func buildProjectsSubmenu(client: RatchetClient, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        for project in client.projects {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.submenu = buildTasksSubmenu(client: client, project: project, actions: actions)
            menu.addItem(item)
        }
        return menu
    }

    private static func buildTasksSubmenu(client: RatchetClient, project: RatchetProject, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        for task in project.tasks {
            let ref = TrackedTaskRef(
                clientId: client.id, clientName: client.name,
                projectId: project.id, projectName: project.name,
                taskId: task.id, taskName: task.name
            )
            menu.addItem(ClosureMenuItem(title: task.name, handler: { actions.startTracking(ref) }))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "New task…", handler: { actions.addTask(client.id, project.id) }))
        return menu
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MenuBuilderStartSubmenuTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/RatchetCore/MenuBuilder.swift Tests/RatchetCoreTests/MenuBuilderStartSubmenuTests.swift
git commit -m "feat: add Start submenu client/project/task drill-down"
```

---

### Task 8: Settings submenu

**Files:**
- Modify: `Sources/RatchetCore/MenuBuilder.swift` (fill in `buildSettingsSubmenu`)
- Test: `Tests/RatchetCoreTests/MenuBuilderSettingsSubmenuTests.swift`

**Interfaces:**
- Consumes: `DataStore.accountEmail` (Task 2), `AppState.launchAtLoginEnabled` (Task 3), `MenuActions.refresh`/`.toggleLaunchAtLogin`/`.openFreeAgent`/`.logOut` (Task 5).
- Produces: nothing new for later tasks — this completes `MenuBuilder`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RatchetCoreTests/MenuBuilderSettingsSubmenuTests.swift
import XCTest
import AppKit
@testable import RatchetCore

final class MenuBuilderSettingsSubmenuTests: XCTestCase {
    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
    }

    func test_layout_matchesSpecOrder() {
        let state = AppState()
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: state, actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), [
            "al@example.com",
            "Refresh projects & tasks",
            "Launch at login",
            "",
            "Open FreeAgent",
            "",
            "Log out",
        ])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertTrue(menu.items[5].isSeparatorItem)
    }

    func test_launchAtLoginCheckmark_reflectsState() {
        let offState = AppState()
        let offMenu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: offState, actions: noopActions())
        XCTAssertEqual(offMenu.items[2].state, .off)

        let onState = AppState()
        onState.setLaunchAtLogin(true)
        let onMenu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: onState, actions: noopActions())
        XCTAssertEqual(onMenu.items[2].state, .on)
    }

    func test_refreshItem_invokesRefreshAction() {
        var refreshed = false
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {},
            refresh: { refreshed = true }, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: AppState(), actions: actions)
        let refreshItem = menu.items[1] as! ClosureMenuItem
        _ = refreshItem.target?.perform(refreshItem.action, with: refreshItem)
        XCTAssertTrue(refreshed)
    }

    func test_logOutItem_invokesLogOutAction() {
        var loggedOut = false
        let actions = MenuActions(
            logIn: {}, logOut: { loggedOut = true }, startTracking: { _ in }, stopTracking: {},
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, quit: {}
        )
        let menu = MenuBuilder.buildSettingsSubmenu(dataStore: FakeDataStore.seeded(), state: AppState(), actions: actions)
        let logOutItem = menu.items[6] as! ClosureMenuItem
        _ = logOutItem.target?.perform(logOutItem.action, with: logOutItem)
        XCTAssertTrue(loggedOut)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MenuBuilderSettingsSubmenuTests`
Expected: FAIL — `buildSettingsSubmenu` currently returns an empty `NSMenu()`.

- [ ] **Step 3: Implement it**

Replace the stub `buildSettingsSubmenu` in `Sources/RatchetCore/MenuBuilder.swift`:

```swift
    static func buildSettingsSubmenu(dataStore: DataStore, state: AppState, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledItem(dataStore.accountEmail))
        menu.addItem(ClosureMenuItem(title: "Refresh projects & tasks", handler: actions.refresh))
        let launchItem = ClosureMenuItem(title: "Launch at login", handler: actions.toggleLaunchAtLogin)
        launchItem.state = state.launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Open FreeAgent", handler: actions.openFreeAgent))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Log out", handler: actions.logOut))
        return menu
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MenuBuilderSettingsSubmenuTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Run the entire test suite to make sure nothing regressed**

Run: `swift test`
Expected: PASS, all tests across every file.

- [ ] **Step 6: Commit**

```bash
git add Sources/RatchetCore/MenuBuilder.swift Tests/RatchetCoreTests/MenuBuilderSettingsSubmenuTests.swift
git commit -m "feat: add Settings submenu"
```

---

### Task 9: StatusItemController — wire the real app together

**Files:**
- Create: `Sources/RatchetCore/StatusItemController.swift`
- Modify: `Sources/Ratchet/AppDelegate.swift` (use `StatusItemController` instead of `PlaceholderStatusItem`)
- Delete: `Sources/RatchetCore/PlaceholderStatusItem.swift`
- Test: `Tests/RatchetCoreTests/StatusItemControllerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–8 (`AppState`, `DataStore`, `FakeDataStore`, `MenuBuilder`, `MenuActions`, `TaskNameValidator`).
- Produces: `class StatusItemController { init(appState: AppState, dataStore: DataStore, statusBar: NSStatusBar) }` — the app's composition root; nothing later depends on it.

This is the AppKit integration layer: it owns the real `NSStatusItem`, rebuilds the menu on every `AppState.onChange`, ticks the elapsed-time display while tracking, swaps the icon, and shows the `NSAlert` for adding a task. The parts that touch a live run loop or modal alerts aren't practically unit-testable; what's tested is the pieces that are — icon selection and menu rebuild on state change — by injecting a fake `NSStatusBar`/`NSStatusItem` is not straightforward with real AppKit classes, so instead this task tests indirectly through `AppState.onChange` wiring and leaves icon/alert behavior to the manual verification in Step 6.

- [ ] **Step 1: Write the failing test for the one piece that's cleanly testable — that constructing the controller triggers an initial menu build without crashing, and that state changes after construction don't throw**

```swift
// Tests/RatchetCoreTests/StatusItemControllerTests.swift
import XCTest
import AppKit
@testable import RatchetCore

final class StatusItemControllerTests: XCTestCase {
    func test_construction_setsInitialMenuOnStatusItem() {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)

        XCTAssertNotNil(controller.statusItemForTesting.menu)
        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Log in with browser")
    }

    func test_stateChange_rebuildsMenu() {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)

        appState.logIn()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Start")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter StatusItemControllerTests`
Expected: FAIL — `StatusItemController` does not exist yet (compile error).

- [ ] **Step 3: Implement StatusItemController**

```swift
// Sources/RatchetCore/StatusItemController.swift
import AppKit

public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let dataStore: DataStore
    private var elapsedTimer: Timer?

    /// Exposed for tests to inspect the live NSStatusItem's menu/icon.
    public var statusItemForTesting: NSStatusItem { statusItem }

    public init(appState: AppState, dataStore: DataStore, statusBar: NSStatusBar = .system) {
        self.appState = appState
        self.dataStore = dataStore
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        appState.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    private lazy var actions: MenuActions = MenuActions(
        logIn: { [weak self] in self?.appState.logIn() },
        logOut: { [weak self] in self?.appState.logOut() },
        startTracking: { [weak self] task in self?.appState.startTracking(task) },
        stopTracking: { [weak self] in self?.appState.stopTracking() },
        refresh: { [weak self] in self?.dataStore.refresh(); self?.rebuild() },
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
        quit: {
            NSApp.terminate(nil)
        }
    )

    private func rebuild() {
        statusItem.menu = MenuBuilder.build(state: appState, dataStore: dataStore, actions: actions)
        updateIcon()
        updateTimer()
    }

    private func updateIcon() {
        let isTracking: Bool
        if case .tracking = appState.screen { isTracking = true } else { isTracking = false }
        let symbolName = isTracking ? "clock.fill" : "clock"
        statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ratchet")
    }

    private func updateTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if case .tracking = appState.screen {
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.statusItem.menu = MenuBuilder.build(state: self.appState, dataStore: self.dataStore, actions: self.actions)
            }
        }
    }

    private func presentAddTaskPrompt(clientId: String, projectId: String) {
        let alert = NSAlert()
        alert.messageText = "New Task"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let name = TaskNameValidator.validate(field.stringValue) else { return }
        _ = dataStore.addTask(name: name, projectId: projectId, clientId: clientId)
        rebuild()
    }
}
```

- [ ] **Step 4: Wire it into the app and delete the placeholder**

```swift
// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dataStore = FakeDataStore.seeded()
        let appState = AppState()
        statusItemController = StatusItemController(appState: appState, dataStore: dataStore)
    }
}
```

Delete `Sources/RatchetCore/PlaceholderStatusItem.swift`.

- [ ] **Step 5: Run the tests to verify they pass, and run the full suite**

Run: `swift test --filter StatusItemControllerTests`
Expected: PASS (2 tests)

Run: `swift test`
Expected: PASS, entire suite, no regressions.

- [ ] **Step 6: Manual verification against the spec's four screens**

Run: `swift run Ratchet`

Walk through and confirm against `docs/superpowers/specs/2026-08-06-ratchet-ui-design.md`:
1. Menu bar shows an outline clock icon, no dock icon.
2. Menu shows "Log in with browser" / separator / "Quit". Click "Log in with browser".
3. Menu now shows "Start" (no most-recent header, since there's no history yet) / separator / "Settings" / "Quit".
4. Open Start → Acme → Website Redesign → click "Development". Menu bar icon becomes filled (`clock.fill`).
5. Menu now shows "Development" / "Acme · Website Redesign" / a ticking "0:00" (increasing every second) / separator / "Stop tracking" / separator / "Settings" / "Quit".
6. Click "Stop tracking". Icon returns to outline. Menu now shows "Start tracking Development" / "Acme · Website Redesign" / "Start" / separator / "Settings" / "Quit".
7. Open Start → Acme → Website Redesign → "New task…", type "QA", click Add. Open the same submenu again and confirm "QA" now appears in the task list.
8. Open Settings → confirm "al@example.com", "Refresh projects & tasks", "Launch at login" (unchecked), separator, "Open FreeAgent", separator, "Log out". Toggle "Launch at login" and reopen Settings to confirm the checkmark persists for the session.
9. Click "Log out". Menu returns to the logged-out screen.
10. Quit via the menu.

- [ ] **Step 7: Commit**

```bash
git add Sources/RatchetCore/StatusItemController.swift Sources/Ratchet/AppDelegate.swift Tests/RatchetCoreTests/StatusItemControllerTests.swift
git rm Sources/RatchetCore/PlaceholderStatusItem.swift
git commit -m "feat: wire StatusItemController into the running app"
```
