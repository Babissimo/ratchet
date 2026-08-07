# FreeAgent API Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `FakeDataStore` with a real FreeAgent-backed `DataStore`, including OAuth login via a custom URL scheme, real start/stop timer wiring, and error handling for all API-backed menu actions.

**Architecture:** A new `FreeAgentKit` SPM target holds all networking/auth/mapping code and depends on `RatchetCore` (for the `DataStore` protocol and `Ratchet*` models). `RatchetCore`'s `DataStore` protocol becomes `async throws` so both `FakeDataStore` and the new `FreeAgentDataStore` conform to the same shape; `StatusItemController` wraps every data-store call in `Task { @MainActor in ... }` and shows an alert on failure. OAuth uses a custom `ratchet://` URL scheme, which requires bundling the SPM executable into a real `.app` via a shell script.

**Tech Stack:** Swift 5.9, Swift Concurrency (`async`/`await`), Foundation `URLSession`, `NSAppleEventManager` (URL scheme callback), Security framework (Keychain), no third-party dependencies.

## Global Constraints

- macOS 13+ deployment target (from `Package.swift`, unchanged).
- No third-party SPM dependencies — matches the existing zero-dependency `Package.swift`.
- Sandbox FreeAgent environment only (`https://api.sandbox.freeagent.com`) — no production URL in this plan.
- OAuth redirect URI is `ratchet://callback` (custom URL scheme), registered as `Info.plist`'s `CFBundleURLTypes`.
- `client_id`/`client_secret` live in a gitignored `Sources/FreeAgentKit/Secrets.swift`; never commit real values.
- User access/refresh tokens live in the macOS Keychain, never in `UserDefaults` or plain files.
- FreeAgent resource IDs (`RatchetClient.id` etc.) are the full FreeAgent resource URL string, not a bare numeric ID.
- `DataStore` protocol methods that fetch or mutate are `async throws`; property getters (`clients`, `accountEmail`, `timeslips`, `lastRefreshedAt`) stay synchronous.
- No live-network integration tests in CI — all `FreeAgentKit` tests use an injected stub transport.

---

### Task 1: Package scaffolding — `FreeAgentKit` target + secrets template

**Files:**
- Modify: `Package.swift`
- Create: `Sources/FreeAgentKit/FreeAgentKit.swift` (placeholder so the target has a source file)
- Create: `Sources/FreeAgentKit/Secrets.swift.example`
- Create: `Tests/FreeAgentKitTests/FreeAgentKitTests.swift` (placeholder)
- Modify: `.gitignore`

**Interfaces:**
- Produces: `FreeAgentKit` target (importable as `import FreeAgentKit`), `FreeAgentKitTests` target. `FreeAgentSecrets` enum shape (`clientID: String`, `clientSecret: String`) that later tasks' `Secrets.swift` must match — this task only creates the `.example` template, not the real (gitignored) file.

- [ ] **Step 1: Update `Package.swift` to add the two new targets**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ratchet",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RatchetCore"),
        .target(name: "FreeAgentKit", dependencies: ["RatchetCore"]),
        .executableTarget(name: "Ratchet", dependencies: ["RatchetCore", "FreeAgentKit"]),
        .testTarget(name: "RatchetCoreTests", dependencies: ["RatchetCore"]),
        .testTarget(name: "FreeAgentKitTests", dependencies: ["FreeAgentKit"]),
    ]
)
```

- [ ] **Step 2: Create the placeholder source file so the target builds**

`Sources/FreeAgentKit/FreeAgentKit.swift`:

```swift
// Sources/FreeAgentKit/FreeAgentKit.swift
// Placeholder — real content added by later tasks in this plan.
```

- [ ] **Step 3: Create the placeholder test file**

`Tests/FreeAgentKitTests/FreeAgentKitTests.swift`:

```swift
import XCTest
@testable import FreeAgentKit

final class FreeAgentKitTests: XCTestCase {
    func test_placeholder() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 4: Create the gitignored secrets template**

`Sources/FreeAgentKit/Secrets.swift.example`:

```swift
// Sources/FreeAgentKit/Secrets.swift
//
// Copy this file to `Secrets.swift` (same directory) and fill in the real
// values from your FreeAgent Developer Dashboard app registration
// (https://dev.freeagent.com/). `Secrets.swift` is gitignored — never
// commit real credentials.

enum FreeAgentSecrets {
    static let clientID = "YOUR_CLIENT_ID"
    static let clientSecret = "YOUR_CLIENT_SECRET"
}
```

- [ ] **Step 5: Add `Secrets.swift` to `.gitignore`**

Append to `.gitignore`:

```
Sources/FreeAgentKit/Secrets.swift
```

- [ ] **Step 6: Create a real (local-only) `Secrets.swift` so the package builds**

Run:
```bash
cp Sources/FreeAgentKit/Secrets.swift.example Sources/FreeAgentKit/Secrets.swift
```
Leave the placeholder values in place for now — later tasks that need a real token exchange will fail gracefully with an auth error until real credentials are filled in, which is fine for everything except the actual manual OAuth verification step in Task 12.

- [ ] **Step 7: Verify the package builds and existing tests still pass**

Run: `swift build && swift test`
Expected: builds clean, all existing `RatchetCoreTests` still pass, `FreeAgentKitTests.test_placeholder` passes.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/FreeAgentKit Tests/FreeAgentKitTests .gitignore
git commit -m "chore: scaffold FreeAgentKit target"
```

---

### Task 2: `DataStore` protocol → `async throws`, new timer methods

**Files:**
- Modify: `Sources/RatchetCore/DataStore.swift`
- Create: `Sources/RatchetCore/DataStoreError.swift`

**Interfaces:**
- Produces: `DataStoreError` enum (`case notFound`, `case underlying(Error)`), and the updated `DataStore` protocol other tasks conform to:

```swift
public protocol DataStore: AnyObject {
    var clients: [RatchetClient] { get }
    var accountEmail: String { get }
    var timeslips: [RatchetTimeslip] { get }
    var lastRefreshedAt: Date? { get }
    func addTask(name: String, projectId: String, clientId: String, isBillable: Bool, status: TaskStatus, billingRate: Double?, billingPeriod: BillingPeriod?) async throws -> RatchetTask
    func addClient(name: String, email: String?, phoneNumber: String?, address1: String?, town: String?, postcode: String?, country: String?) async throws -> RatchetClient
    func addProject(name: String, clientId: String, status: ProjectStatus, currency: String, budget: Double, budgetUnits: BudgetUnits, hoursPerDay: Double, normalBillingRate: Double, billingPeriod: BillingPeriod, usesProjectInvoiceSequence: Bool, contractPoReference: String?, startsOn: Date?, endsOn: Date?) async throws -> RatchetProject
    func logTime(taskId: String, projectId: String, clientId: String, date: Date, hours: Double, comment: String?) async throws -> RatchetTimeslip
    func refresh() async throws
    func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip
    func stopTimer() async throws -> RatchetTimeslip?
}
```

- [ ] **Step 1: Create `DataStoreError`**

`Sources/RatchetCore/DataStoreError.swift`:

```swift
import Foundation

public enum DataStoreError: Error, Equatable {
    case notFound
    case underlying(String)

    public static func == (lhs: DataStoreError, rhs: DataStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound): return true
        case (.underlying(let a), .underlying(let b)): return a == b
        default: return false
        }
    }
}
```

- [ ] **Step 2: Rewrite `DataStore.swift` with the new signatures**

`Sources/RatchetCore/DataStore.swift`:

```swift
import Foundation

public protocol DataStore: AnyObject {
    var clients: [RatchetClient] { get }
    var accountEmail: String { get }
    var timeslips: [RatchetTimeslip] { get }
    var lastRefreshedAt: Date? { get }

    func addTask(
        name: String,
        projectId: String,
        clientId: String,
        isBillable: Bool,
        status: TaskStatus,
        billingRate: Double?,
        billingPeriod: BillingPeriod?
    ) async throws -> RatchetTask

    func addClient(
        name: String,
        email: String?,
        phoneNumber: String?,
        address1: String?,
        town: String?,
        postcode: String?,
        country: String?
    ) async throws -> RatchetClient

    func addProject(
        name: String,
        clientId: String,
        status: ProjectStatus,
        currency: String,
        budget: Double,
        budgetUnits: BudgetUnits,
        hoursPerDay: Double,
        normalBillingRate: Double,
        billingPeriod: BillingPeriod,
        usesProjectInvoiceSequence: Bool,
        contractPoReference: String?,
        startsOn: Date?,
        endsOn: Date?
    ) async throws -> RatchetProject

    func logTime(
        taskId: String,
        projectId: String,
        clientId: String,
        date: Date,
        hours: Double,
        comment: String?
    ) async throws -> RatchetTimeslip

    func refresh() async throws

    /// Starts (or resumes) today's timer for the given task. Returns the
    /// timeslip the timer is running on; its effective start instant is
    /// the UI's elapsed-time baseline.
    func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip

    /// Stops whichever timeslip currently has a running timer. Returns
    /// the updated timeslip, or nil if nothing was running.
    func stopTimer() async throws -> RatchetTimeslip?
}
```

- [ ] **Step 3: Confirm the project no longer builds (expected — `FakeDataStore` doesn't conform yet)**

Run: `swift build`
Expected: FAIL — `FakeDataStore` does not conform to `DataStore` (missing `async`/`throws`, missing `startTimer`/`stopTimer`). This confirms the protocol change took effect; Task 3 fixes the conformance.

- [ ] **Step 4: Commit**

```bash
git add Sources/RatchetCore/DataStore.swift Sources/RatchetCore/DataStoreError.swift
git commit -m "feat: make DataStore protocol async throws, add timer methods"
```

---

### Task 3: Update `FakeDataStore` to conform, add in-memory timer tracking

**Files:**
- Modify: `Sources/RatchetCore/FakeDataStore.swift`
- Modify: `Tests/RatchetCoreTests/FakeDataStoreTests.swift`

**Interfaces:**
- Consumes: `DataStore` protocol and `DataStoreError` from Task 2.
- Produces: `FakeDataStore` fully conforms to `DataStore`; adds `startTimer`/`stopTimer` behavior other tasks (StatusItemController, its tests) rely on.

- [ ] **Step 1: Rewrite `FakeDataStore.swift`**

Replace the whole file:

```swift
import Foundation

public final class FakeDataStore: DataStore {
    public private(set) var clients: [RatchetClient]
    public let accountEmail: String
    public private(set) var refreshCount = 0
    public private(set) var timeslips: [RatchetTimeslip] = []
    public private(set) var lastRefreshedAt: Date?

    /// id of the timeslip with a currently-running timer, if any.
    private var runningTimeslipId: String?

    private let clock: () -> Date

    public init(clients: [RatchetClient], accountEmail: String, clock: @escaping () -> Date = Date.init) {
        self.clients = clients
        self.accountEmail = accountEmail
        self.clock = clock
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

    public func addTask(
        name: String,
        projectId: String,
        clientId: String,
        isBillable: Bool = true,
        status: TaskStatus = .active,
        billingRate: Double? = nil,
        billingPeriod: BillingPeriod? = nil
    ) async throws -> RatchetTask {
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { throw DataStoreError.notFound }
        guard let projectIndex = clients[clientIndex].projects.firstIndex(where: { $0.id == projectId }) else { throw DataStoreError.notFound }

        let newTask = RatchetTask(
            id: "task-\(UUID().uuidString.prefix(8))",
            name: name,
            isBillable: isBillable,
            status: status,
            billingRate: billingRate,
            billingPeriod: billingPeriod
        )
        var projects = clients[clientIndex].projects
        let existingProject = projects[projectIndex]
        projects[projectIndex] = RatchetProject(
            id: existingProject.id,
            name: existingProject.name,
            tasks: existingProject.tasks + [newTask],
            status: existingProject.status,
            currency: existingProject.currency,
            budget: existingProject.budget,
            budgetUnits: existingProject.budgetUnits,
            hoursPerDay: existingProject.hoursPerDay,
            normalBillingRate: existingProject.normalBillingRate,
            billingPeriod: existingProject.billingPeriod,
            usesProjectInvoiceSequence: existingProject.usesProjectInvoiceSequence,
            contractPoReference: existingProject.contractPoReference,
            startsOn: existingProject.startsOn,
            endsOn: existingProject.endsOn
        )
        clients[clientIndex] = RatchetClient(
            id: clients[clientIndex].id,
            name: clients[clientIndex].name,
            projects: projects,
            email: clients[clientIndex].email,
            phoneNumber: clients[clientIndex].phoneNumber,
            address1: clients[clientIndex].address1,
            town: clients[clientIndex].town,
            postcode: clients[clientIndex].postcode,
            country: clients[clientIndex].country
        )
        return newTask
    }

    public func addClient(
        name: String,
        email: String? = nil,
        phoneNumber: String? = nil,
        address1: String? = nil,
        town: String? = nil,
        postcode: String? = nil,
        country: String? = nil
    ) async throws -> RatchetClient {
        let newClient = RatchetClient(
            id: "client-\(UUID().uuidString.prefix(8))",
            name: name,
            projects: [],
            email: email,
            phoneNumber: phoneNumber,
            address1: address1,
            town: town,
            postcode: postcode,
            country: country
        )
        clients.append(newClient)
        return newClient
    }

    public func addProject(
        name: String,
        clientId: String,
        status: ProjectStatus,
        currency: String,
        budget: Double,
        budgetUnits: BudgetUnits,
        hoursPerDay: Double,
        normalBillingRate: Double,
        billingPeriod: BillingPeriod,
        usesProjectInvoiceSequence: Bool,
        contractPoReference: String? = nil,
        startsOn: Date? = nil,
        endsOn: Date? = nil
    ) async throws -> RatchetProject {
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { throw DataStoreError.notFound }

        let newProject = RatchetProject(
            id: "proj-\(UUID().uuidString.prefix(8))",
            name: name,
            tasks: [],
            status: status,
            currency: currency,
            budget: budget,
            budgetUnits: budgetUnits,
            hoursPerDay: hoursPerDay,
            normalBillingRate: normalBillingRate,
            billingPeriod: billingPeriod,
            usesProjectInvoiceSequence: usesProjectInvoiceSequence,
            contractPoReference: contractPoReference,
            startsOn: startsOn,
            endsOn: endsOn
        )
        var projects = clients[clientIndex].projects
        projects.append(newProject)
        clients[clientIndex] = RatchetClient(
            id: clients[clientIndex].id,
            name: clients[clientIndex].name,
            projects: projects,
            email: clients[clientIndex].email,
            phoneNumber: clients[clientIndex].phoneNumber,
            address1: clients[clientIndex].address1,
            town: clients[clientIndex].town,
            postcode: clients[clientIndex].postcode,
            country: clients[clientIndex].country
        )
        return newProject
    }

    public func logTime(
        taskId: String,
        projectId: String,
        clientId: String,
        date: Date,
        hours: Double,
        comment: String? = nil
    ) async throws -> RatchetTimeslip {
        guard let client = clients.first(where: { $0.id == clientId }),
              let project = client.projects.first(where: { $0.id == projectId }),
              project.tasks.contains(where: { $0.id == taskId })
        else { throw DataStoreError.notFound }

        let entry = RatchetTimeslip(
            id: "timeslip-\(UUID().uuidString.prefix(8))",
            clientId: clientId,
            projectId: projectId,
            taskId: taskId,
            date: date,
            hours: hours,
            comment: comment
        )
        timeslips.append(entry)
        return entry
    }

    public func refresh() async throws {
        refreshCount += 1
        lastRefreshedAt = clock()
    }

    public func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip {
        guard let client = clients.first(where: { $0.id == clientId }),
              let project = client.projects.first(where: { $0.id == projectId }),
              project.tasks.contains(where: { $0.id == taskId })
        else { throw DataStoreError.notFound }

        if let runningTimeslipId, let index = timeslips.firstIndex(where: { $0.id == runningTimeslipId }) {
            _ = index // previous timer implicitly stops when a new one starts
        }

        let entry = RatchetTimeslip(
            id: "timeslip-\(UUID().uuidString.prefix(8))",
            clientId: clientId,
            projectId: projectId,
            taskId: taskId,
            date: clock(),
            hours: 0,
            comment: nil
        )
        timeslips.append(entry)
        runningTimeslipId = entry.id
        return entry
    }

    public func stopTimer() async throws -> RatchetTimeslip? {
        guard let runningTimeslipId, let index = timeslips.firstIndex(where: { $0.id == runningTimeslipId }) else {
            return nil
        }
        self.runningTimeslipId = nil
        return timeslips[index]
    }
}
```

- [ ] **Step 2: Update `FakeDataStoreTests.swift` for `async throws`**

Replace the whole file:

```swift
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

    func test_addTask_appendsToMatchingProjectAndReturnsIt() async throws {
        let store = FakeDataStore.seeded()
        let clientId = store.clients[0].id
        let projectId = store.clients[0].projects[0].id

        let created = try await store.addTask(
            name: "QA", projectId: projectId, clientId: clientId,
            isBillable: true, status: .active, billingRate: nil, billingPeriod: nil
        )

        XCTAssertEqual(created.name, "QA")
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development", "Design", "QA"])
    }

    func test_addTask_throwsNotFoundForUnknownProject() async {
        let store = FakeDataStore.seeded()
        do {
            _ = try await store.addTask(
                name: "QA", projectId: "nonexistent", clientId: store.clients[0].id,
                isBillable: true, status: .active, billingRate: nil, billingPeriod: nil
            )
            XCTFail("expected DataStoreError.notFound")
        } catch DataStoreError.notFound {
            // expected
        } catch {
            XCTFail("expected DataStoreError.notFound, got \(error)")
        }
    }

    func test_refresh_incrementsRefreshCount() async throws {
        let store = FakeDataStore.seeded()
        XCTAssertEqual(store.refreshCount, 0)
        try await store.refresh()
        XCTAssertEqual(store.refreshCount, 1)
    }

    func test_startTimer_thenStopTimer_returnsTheRunningTimeslip() async throws {
        let store = FakeDataStore.seeded()
        let clientId = store.clients[0].id
        let projectId = store.clients[0].projects[0].id
        let taskId = store.clients[0].projects[0].tasks[0].id

        let started = try await store.startTimer(taskId: taskId, projectId: projectId, clientId: clientId)
        XCTAssertEqual(started.taskId, taskId)

        let stopped = try await store.stopTimer()
        XCTAssertEqual(stopped?.id, started.id)

        let stoppedAgain = try await store.stopTimer()
        XCTAssertNil(stoppedAgain)
    }

    func test_startTimer_throwsNotFoundForUnknownTask() async {
        let store = FakeDataStore.seeded()
        do {
            _ = try await store.startTimer(taskId: "nonexistent", projectId: store.clients[0].projects[0].id, clientId: store.clients[0].id)
            XCTFail("expected DataStoreError.notFound")
        } catch DataStoreError.notFound {
            // expected
        } catch {
            XCTFail("expected DataStoreError.notFound, got \(error)")
        }
    }
}
```

- [ ] **Step 3: Build and run RatchetCore tests**

Run: `swift build && swift test --filter RatchetCoreTests`
Expected: still fails — `MenuBuilderSettingsSubmenuTests.swift` (`store.refresh()` at line 40) and `StatusItemController.swift` (several `dataStore.*` call sites) don't compile yet. That's fixed in Tasks 4 and 5. For this task, confirm the *new* failures are only in those two files (not in `FakeDataStore.swift`/`FakeDataStoreTests.swift` themselves) by checking the compiler output names those files.

- [ ] **Step 4: Commit**

```bash
git add Sources/RatchetCore/FakeDataStore.swift Tests/RatchetCoreTests/FakeDataStoreTests.swift
git commit -m "feat: conform FakeDataStore to async DataStore, add timer tracking"
```

---

### Task 4: `AppState.startTracking` accepts an explicit start time

**Files:**
- Modify: `Sources/RatchetCore/AppState.swift`
- Modify: `Tests/RatchetCoreTests/AppStateTests.swift`

**Interfaces:**
- Produces: `AppState.startTracking(_ task: TrackedTaskRef, startedAt: Date? = nil)` — default `nil` preserves every existing call site (`state.startTracking(sampleTask)` in `AppStateTests.swift` and the `MenuBuilder*Tests.swift` files) unchanged.

- [ ] **Step 1: Add the failing test**

In `Tests/RatchetCoreTests/AppStateTests.swift`, add:

```swift
    func test_startTracking_withExplicitStartedAt_usesThatInstantNotClock() {
        let clockDate = Date(timeIntervalSince1970: 2_000_000_000)
        let explicitStart = Date(timeIntervalSince1970: 1_000_000_000)
        let state = AppState(clock: { clockDate })

        state.startTracking(sampleTask, startedAt: explicitStart)

        guard case .tracking(_, let startedAt) = state.screen else {
            return XCTFail("expected .tracking, got \(state.screen)")
        }
        // .tracking only shows once logged in
        state.logIn()
        guard case .tracking = state.screen else { return }
        XCTAssertEqual(startedAt, explicitStart)
    }
```

Note: check the existing `sampleTask` fixture and whether tests call `logIn()` before asserting `.tracking` — match the pattern already used elsewhere in this file (read the file first; `AppState.screen` returns `.loggedOut` unless `isLoggedIn`, so existing tests must call `logIn()` before `startTracking` to see `.tracking`). Adjust the test above to call `state.logIn()` before `state.startTracking(...)` if that's the established pattern, and remove the redundant second `logIn()` call — mirror whatever the neighboring tests in the file already do exactly.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AppStateTests`
Expected: FAIL — `startTracking` doesn't accept a `startedAt` argument yet (compile error).

- [ ] **Step 3: Update `AppState.swift`**

Change:
```swift
    public func startTracking(_ task: TrackedTaskRef) {
        trackingTask = task
        trackingStartedAt = clock()
        mostRecent = task
        onChange?()
    }
```
to:
```swift
    public func startTracking(_ task: TrackedTaskRef, startedAt: Date? = nil) {
        trackingTask = task
        trackingStartedAt = startedAt ?? clock()
        mostRecent = task
        onChange?()
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AppStateTests`
Expected: PASS, and all other `AppStateTests` still pass unchanged (they call `startTracking(sampleTask)` with no second argument).

- [ ] **Step 5: Commit**

```bash
git add Sources/RatchetCore/AppState.swift Tests/RatchetCoreTests/AppStateTests.swift
git commit -m "feat: let AppState.startTracking accept an explicit start instant"
```

---

### Task 5: `StatusItemController` — async wiring + API error alerts

**Files:**
- Modify: `Sources/RatchetCore/StatusItemController.swift`
- Modify: `Tests/RatchetCoreTests/MenuBuilderSettingsSubmenuTests.swift`

**Interfaces:**
- Consumes: `DataStore` (Task 2/3, `async throws`), `AppState.startTracking(_:startedAt:)` (Task 4).
- Produces: `StatusItemController.presentAPIError(_:action:)` — a private helper other tasks don't call directly, but its existence and behavior (shows an `NSAlert`, message format `"Couldn't <action>: <error description>."`) is depended on by manual verification later in this plan.

This task changes every `MenuActions` closure that touches `dataStore` and every internal `run*Form`/`run*Prompt` method that calls `dataStore.addTask`/`addClient`/`addProject`/`logTime`.

- [ ] **Step 1: Fix the now-broken test call site first**

In `Tests/RatchetCoreTests/MenuBuilderSettingsSubmenuTests.swift`, change:

```swift
    func test_refreshItem_showsLastRefreshedTimestampAfterRefresh() {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let store = FakeDataStore(clients: [], accountEmail: "al@example.com", clock: { fixedDate })
        store.refresh()
```
to:
```swift
    func test_refreshItem_showsLastRefreshedTimestampAfterRefresh() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let store = FakeDataStore(clients: [], accountEmail: "al@example.com", clock: { fixedDate })
        try await store.refresh()
```

- [ ] **Step 2: Add `presentAPIError` and update the `actions` lazy property**

In `Sources/RatchetCore/StatusItemController.swift`, replace the `actions` lazy var:

```swift
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
```

(Note: `RatchetTimeslip.date` is used as `startTimer`'s elapsed-time baseline here as a placeholder for `FakeDataStore`/tests — Task 13's `FreeAgentDataStore.startTimer` returns the *real* `timer.start_from` from FreeAgent mapped into that same `date` field, so this call site doesn't need to change again later. Confirm this mapping decision matches what Task 10/13 actually implement; if timeslip's timer-start ends up on a different field, update this call site to match — search for `startTimer` usages before renaming anything.)

- [ ] **Step 3: Update `runAddTaskPrompt`**

Replace the tail of the method (from `_ = dataStore.addTask(` through `rebuild()`):

```swift
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
```

- [ ] **Step 4: Update `runLogPastTimeForm`**

Replace from `_ = dataStore.logTime(` through the end of the method:

```swift
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
```

- [ ] **Step 5: Update `runLogPastTimeForNewTaskForm`**

Replace from `guard let newTask = dataStore.addTask(` through the end of the method:

```swift
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
```

- [ ] **Step 6: Update `runAddClientForm`**

Replace from `_ = dataStore.addClient(` through `rebuild()`:

```swift
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
```

- [ ] **Step 7: Update `runAddProjectForm`**

Replace from `_ = dataStore.addProject(` through `rebuild()`:

```swift
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
```

- [ ] **Step 8: Build and run all `RatchetCoreTests`**

Run: `swift build && swift test --filter RatchetCoreTests`
Expected: PASS, all tests green (including the `MenuBuilderSettingsSubmenuTests` fix from Step 1).

- [ ] **Step 9: Commit**

```bash
git add Sources/RatchetCore/StatusItemController.swift Tests/RatchetCoreTests/MenuBuilderSettingsSubmenuTests.swift
git commit -m "feat: wrap StatusItemController's data-store calls in async Task, show API error alerts"
```

---

### Task 6: App bundling script — `Ratchet.app` with `ratchet://` URL scheme

**Files:**
- Create: `scripts/build-app.sh`

**Interfaces:**
- Produces: `.build/Ratchet.app` (a real macOS app bundle) when run; used manually from here on for anything touching OAuth. `swift run`/`swift build` continue to work unchanged for everyday UI iteration.

- [ ] **Step 1: Write the script**

`scripts/build-app.sh`:

```bash
#!/bin/bash
# Builds Ratchet.app, a real macOS app bundle wrapping the SPM executable.
#
# SPM's `swift build` alone only produces a raw Mach-O binary — macOS only
# routes a custom URL scheme (ratchet://) to an app that Launch Services
# knows about via a bundle's Info.plist. This script assembles that bundle
# around the SPM-built binary rather than converting the project to an
# Xcode project.
#
# Usage: scripts/build-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building Ratchet ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/Ratchet"
APP_DIR=".build/Ratchet.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/Ratchet"

cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Ratchet</string>
    <key>CFBundleDisplayName</key>
    <string>Ratchet</string>
    <key>CFBundleIdentifier</key>
    <string>com.ratchet.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Ratchet</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.ratchet.app.oauth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>ratchet</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

touch "$APP_DIR"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_DIR"
fi

echo "Built: $APP_DIR"
echo "Run with: open $APP_DIR"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/build-app.sh`

- [ ] **Step 3: Run it and verify the bundle's Info.plist is well-formed**

Run:
```bash
scripts/build-app.sh debug
plutil -convert json -o - .build/Ratchet.app/Contents/Info.plist
```
Expected: valid JSON output; verify by eye (or `| grep`) that it contains `"CFBundleIdentifier":"com.ratchet.app"`, `"LSUIElement":true`, and `"CFBundleURLSchemes":["ratchet"]`.

- [ ] **Step 4: Verify the app launches**

Run: `open .build/Ratchet.app`
Expected: a clock icon appears in the menu bar (same as `swift run` today), no Dock icon (LSUIElement). Quit it via the menu's Quit item before continuing.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-app.sh
git commit -m "feat: add build-app.sh to bundle Ratchet.app with the ratchet:// URL scheme"
```

---

### Task 7: `FreeAgentEnvironment` and `FreeAgentError`

**Files:**
- Create: `Sources/FreeAgentKit/FreeAgentEnvironment.swift`
- Create: `Sources/FreeAgentKit/FreeAgentError.swift`
- Modify: `Sources/FreeAgentKit/FreeAgentKit.swift` (delete placeholder content — no longer needed once real files exist)

**Interfaces:**
- Produces: `FreeAgentEnvironment` (`.sandbox` case with `apiBaseURL`, `authorizeURL`, `tokenURL`), `FreeAgentError` enum (`.network(Error)`, `.unauthorized`, `.decoding(Error)`, `.apiError(status: Int, message: String?)`, `.authCancelled`, `.authTimedOut`, `.stateMismatch`) that Tasks 8–13 all throw/catch.

- [ ] **Step 1: Delete the placeholder file's content** (leave the file — Swift needs at least the module to have sources, but this content is superseded)

Empty out `Sources/FreeAgentKit/FreeAgentKit.swift` to just:
```swift
// Sources/FreeAgentKit/FreeAgentKit.swift
```

- [ ] **Step 2: Create `FreeAgentEnvironment.swift`**

```swift
import Foundation

public enum FreeAgentEnvironment {
    case sandbox

    public var apiBaseURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2")!
        }
    }

    public var authorizeURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2/approve_app")!
        }
    }

    public var tokenURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://api.sandbox.freeagent.com/v2/token_endpoint")!
        }
    }
}
```

- [ ] **Step 3: Create `FreeAgentError.swift`**

```swift
import Foundation

public enum FreeAgentError: Error, CustomStringConvertible {
    case network(Error)
    case unauthorized
    case decoding(Error)
    case apiError(status: Int, message: String?)
    case authCancelled
    case authTimedOut
    case stateMismatch

    public var description: String {
        switch self {
        case .network(let error):
            return "network error (\(error.localizedDescription))"
        case .unauthorized:
            return "session expired, please log in again"
        case .decoding(let error):
            return "couldn't understand FreeAgent's response (\(error.localizedDescription))"
        case .apiError(let status, let message):
            return message ?? "FreeAgent returned an error (status \(status))"
        case .authCancelled:
            return "login was cancelled"
        case .authTimedOut:
            return "login timed out — please try again"
        case .stateMismatch:
            return "login response didn't match the request (possible tampering) — please try again"
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds (nothing references these types yet, but they compile standalone).

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeAgentKit/FreeAgentKit.swift Sources/FreeAgentKit/FreeAgentEnvironment.swift Sources/FreeAgentKit/FreeAgentError.swift
git commit -m "feat: add FreeAgentEnvironment and FreeAgentError"
```

---

### Task 8: Token storage — `FreeAgentTokens` + `KeychainTokenStore`

**Files:**
- Create: `Sources/FreeAgentKit/FreeAgentTokens.swift`
- Create: `Sources/FreeAgentKit/KeychainTokenStore.swift`
- Create: `Tests/FreeAgentKitTests/KeychainTokenStoreTests.swift`

**Interfaces:**
- Produces:
```swift
public struct FreeAgentTokens: Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public init(accessToken: String, refreshToken: String, expiresAt: Date)
    public var isExpired: Bool { get } // true if within 60s of expiresAt or past it
}

public final class KeychainTokenStore {
    public init(service: String = "com.ratchet.freeagent")
    public func load() -> FreeAgentTokens?
    public func save(_ tokens: FreeAgentTokens)
    public func clear()
}
```
Task 9 (`FreeAgentAPIClient`) and Task 13 (`FreeAgentDataStore`) consume `KeychainTokenStore.load()`/`.save()`. Task 14 (`AppDelegate`) consumes `.load() != nil` as the "already logged in" check and `.clear()` on log out.

- [ ] **Step 1: Create `FreeAgentTokens.swift`**

```swift
import Foundation

public struct FreeAgentTokens: Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True once within 60 seconds of expiry (or past it) — leaves headroom
    /// so a request built "now" doesn't land as expired mid-flight.
    public var isExpired: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }
}
```

- [ ] **Step 2: Create `KeychainTokenStore.swift`**

```swift
import Foundation
import Security

public final class KeychainTokenStore {
    private let service: String
    private let account = "default"

    public init(service: String = "com.ratchet.freeagent") {
        self.service = service
    }

    public func load() -> FreeAgentTokens? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        query.removeValue(forKey: kSecReturnData as String)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FreeAgentTokens.self, from: data)
    }

    public func save(_ tokens: FreeAgentTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 3: Write the test**

`Tests/FreeAgentKitTests/KeychainTokenStoreTests.swift`:

```swift
import XCTest
@testable import FreeAgentKit

final class KeychainTokenStoreTests: XCTestCase {
    // Unique service per test run so parallel/repeated runs never collide
    // with a stale Keychain item from a previous run.
    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
    }

    func test_load_returnsNilWhenNothingSaved() {
        let store = makeStore()
        XCTAssertNil(store.load())
    }

    func test_save_thenLoad_roundTrips() {
        let store = makeStore()
        let tokens = FreeAgentTokens(accessToken: "access", refreshToken: "refresh", expiresAt: Date(timeIntervalSinceNow: 3600))

        store.save(tokens)

        XCTAssertEqual(store.load(), tokens)
        store.clear()
    }

    func test_save_overwritesPreviousValue() {
        let store = makeStore()
        store.save(FreeAgentTokens(accessToken: "first", refreshToken: "r1", expiresAt: Date()))
        store.save(FreeAgentTokens(accessToken: "second", refreshToken: "r2", expiresAt: Date()))

        XCTAssertEqual(store.load()?.accessToken, "second")
        store.clear()
    }

    func test_clear_removesTheValue() {
        let store = makeStore()
        store.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date()))

        store.clear()

        XCTAssertNil(store.load())
    }

    func test_isExpired_trueWithin60SecondsOfExpiry() {
        let almostExpired = FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 30))
        let farFromExpiry = FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600))

        XCTAssertTrue(almostExpired.isExpired)
        XCTAssertFalse(farFromExpiry.isExpired)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter FreeAgentKitTests`
Expected: PASS. (If sandboxed test execution denies Keychain access entirely, that'll show as a clear `errSecSuccess`-mismatch failure on `save`/`load` — if so, note it and confirm by running the same test target from `swift test` directly in Terminal rather than through any sandboxing wrapper, since Keychain access from a command-line test binary run by the logged-in user should work without special entitlements.)

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeAgentKit/FreeAgentTokens.swift Sources/FreeAgentKit/KeychainTokenStore.swift Tests/FreeAgentKitTests/KeychainTokenStoreTests.swift
git commit -m "feat: add FreeAgentTokens and Keychain-backed token storage"
```

---

### Task 9: `FreeAgentAPIClient` — networking core with pagination and 401-retry

**Files:**
- Create: `Sources/FreeAgentKit/FreeAgentAPIClient.swift`
- Create: `Tests/FreeAgentKitTests/FreeAgentAPIClientTests.swift`

**Interfaces:**
- Consumes: `FreeAgentEnvironment`, `FreeAgentError`, `KeychainTokenStore`, `FreeAgentTokens` (Tasks 7–8).
- Produces:
```swift
public protocol FreeAgentTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class FreeAgentAPIClient {
    public init(environment: FreeAgentEnvironment, tokenStore: KeychainTokenStore, transport: FreeAgentTransport = URLSessionTransport())
    public func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T
    public func getList<T: Decodable>(_ path: String, query: [URLQueryItem], listKey: String) async throws -> [T]
    public func post<T: Decodable, Body: Encodable>(_ path: String, envelopeKey: String, query: [URLQueryItem], body: Body) async throws -> T
    public func delete(_ path: String) async throws
    public func exchangeAuthorizationCode(_ code: String, redirectURI: String) async throws -> FreeAgentTokens
}
```
Task 10 (DTOs) supplies the `T`/`Body` types. Task 13 (`FreeAgentDataStore`) is the primary caller of `get`/`getList`/`post`/`delete`. Task 11 (`FreeAgentAuthenticator`) calls `exchangeAuthorizationCode`.

- [ ] **Step 1: Write the transport protocol + real implementation**

`Sources/FreeAgentKit/FreeAgentAPIClient.swift` (part 1 — transport):

```swift
import Foundation

/// Abstraction over "send an HTTP request, get back a response" so tests
/// can inject a stub instead of hitting the network.
public protocol FreeAgentTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: FreeAgentTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FreeAgentError.network(URLError(.badServerResponse))
        }
        return (data, httpResponse)
    }
}
```

- [ ] **Step 2: Write `FreeAgentAPIClient` itself (append to the same file)**

```swift
public final class FreeAgentAPIClient {
    private let environment: FreeAgentEnvironment
    private let tokenStore: KeychainTokenStore
    private let transport: FreeAgentTransport
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    public init(environment: FreeAgentEnvironment, tokenStore: KeychainTokenStore, transport: FreeAgentTransport = URLSessionTransport()) {
        self.environment = environment
        self.tokenStore = tokenStore
        self.transport = transport
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Authenticated requests

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await authenticatedRequest(path: path, method: "GET", query: query, body: Data?.none)
        return try decode(data)
    }

    /// Follows FreeAgent's `page`/`per_page` pagination until a page comes
    /// back with fewer than `per_page` items, collecting the full list.
    public func getList<T: Decodable>(_ path: String, query: [URLQueryItem] = [], listKey: String) async throws -> [T] {
        var page = 1
        let perPage = 100
        var all: [T] = []
        while true {
            var pageQuery = query
            pageQuery.append(URLQueryItem(name: "page", value: String(page)))
            pageQuery.append(URLQueryItem(name: "per_page", value: String(perPage)))
            let data = try await authenticatedRequest(path: path, method: "GET", query: pageQuery, body: Data?.none)
            let envelope = try decode(data, as: [String: [T]].self)
            let items = envelope[listKey] ?? []
            all.append(contentsOf: items)
            if items.count < perPage { break }
            page += 1
        }
        return all
    }

    public func post<T: Decodable, Body: Encodable>(_ path: String, envelopeKey: String, query: [URLQueryItem] = [], body: Body) async throws -> T {
        let bodyData = try jsonEncoder.encode([envelopeKey: body])
        let data = try await authenticatedRequest(path: path, method: "POST", query: query, body: bodyData)
        return try decode(data)
    }

    public func delete(_ path: String) async throws {
        _ = try await authenticatedRequest(path: path, method: "DELETE", query: [], body: Data?.none)
    }

    // MARK: - OAuth token exchange (unauthenticated)

    public func exchangeAuthorizationCode(_ code: String, redirectURI: String) async throws -> FreeAgentTokens {
        var request = URLRequest(url: environment.tokenURL)
        request.httpMethod = "POST"
        let credentials = "\(FreeAgentSecrets.clientID):\(FreeAgentSecrets.clientSecret)"
        let encodedCredentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=authorization_code&code=\(urlEncoded(code))&redirect_uri=\(urlEncoded(redirectURI))"
        request.httpBody = Data(form.utf8)

        let (data, response) = try await send(request)
        try throwIfError(status: response.statusCode, data: data)
        return try decodeTokenResponse(data)
    }

    public func refreshTokens(_ refreshToken: String) async throws -> FreeAgentTokens {
        var request = URLRequest(url: environment.tokenURL)
        request.httpMethod = "POST"
        let credentials = "\(FreeAgentSecrets.clientID):\(FreeAgentSecrets.clientSecret)"
        let encodedCredentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=refresh_token&refresh_token=\(urlEncoded(refreshToken))"
        request.httpBody = Data(form.utf8)

        let (data, response) = try await send(request)
        try throwIfError(status: response.statusCode, data: data)
        return try decodeTokenResponse(data)
    }

    // MARK: - Private helpers

    private func authenticatedRequest(path: String, method: String, query: [URLQueryItem], body: Data?, isRetry: Bool = false) async throws -> Data {
        guard var tokens = tokenStore.load() else { throw FreeAgentError.unauthorized }
        if tokens.isExpired {
            tokens = try await refreshTokens(tokens.refreshToken)
            tokenStore.save(tokens)
        }

        var url = path.hasPrefix("http") ? URL(string: path)! : environment.apiBaseURL.appendingPathComponent(path)
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = query
            url = components.url!
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await send(request)

        if response.statusCode == 401 && !isRetry {
            let refreshed = try await refreshTokens(tokens.refreshToken)
            tokenStore.save(refreshed)
            return try await authenticatedRequest(path: path, method: method, query: query, body: body, isRetry: true)
        }
        try throwIfError(status: response.statusCode, data: data)
        return data
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as FreeAgentError {
            throw error
        } catch {
            throw FreeAgentError.network(error)
        }
    }

    private func throwIfError(status: Int, data: Data) throws {
        guard status >= 400 else { return }
        if status == 401 { throw FreeAgentError.unauthorized }
        let message = (try? decode(data, as: [String: String].self))?["error"]
        throw FreeAgentError.apiError(status: status, message: message)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try decode(data, as: T.self)
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try jsonDecoder.decode(type, from: data)
        } catch {
            throw FreeAgentError.decoding(error)
        }
    }

    private func decodeTokenResponse(_ data: Data) throws -> FreeAgentTokens {
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Double

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let decoder = JSONDecoder()
        let response = try decoder.decode(TokenResponse.self, from: data)
        return FreeAgentTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date(timeIntervalSinceNow: response.expiresIn)
        )
    }

    private func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        return set
    }()
}
```

- [ ] **Step 3: Write the tests using a stub transport**

`Tests/FreeAgentKitTests/FreeAgentAPIClientTests.swift`:

```swift
import XCTest
@testable import FreeAgentKit

private final class StubTransport: FreeAgentTransport {
    struct Call {
        let request: URLRequest
    }
    var calls: [Call] = []
    /// Queue of (statusCode, body) pairs returned in order, one per call.
    var responses: [(Int, Data)] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(Call(request: request))
        guard !responses.isEmpty else {
            fatalError("StubTransport ran out of queued responses")
        }
        let (status, body) = responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

final class FreeAgentAPIClientTests: XCTestCase {
    private func makeStore(expired: Bool = false) -> KeychainTokenStore {
        let store = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
        store.save(FreeAgentTokens(
            accessToken: "valid-access-token",
            refreshToken: "valid-refresh-token",
            expiresAt: Date(timeIntervalSinceNow: expired ? -10 : 3600)
        ))
        return store
    }

    func test_get_sendsBearerTokenAndDecodesJSON() async throws {
        struct Thing: Decodable, Equatable { let name: String }
        let transport = StubTransport()
        transport.responses = [(200, Data(#"{"name":"hello"}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result: Thing = try await client.get("things/1")

        XCTAssertEqual(result, Thing(name: "hello"))
        XCTAssertEqual(transport.calls[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer valid-access-token")
        store.clear()
    }

    func test_getList_followsPaginationUntilShortPage() async throws {
        struct Item: Decodable, Equatable { let id: Int }
        let transport = StubTransport()
        let fullPage = (1...100).map { "{\"id\":\($0)}" }.joined(separator: ",")
        transport.responses = [
            (200, Data(#"{"items":["#.utf8 + Data(fullPage.utf8) + Data("]}".utf8)),
            (200, Data(#"{"items":[{"id":101}]}"#.utf8)),
        ]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        let result: [Item] = try await client.getList("items", listKey: "items")

        XCTAssertEqual(result.count, 101)
        XCTAssertEqual(transport.calls.count, 2)
        store.clear()
    }

    func test_authenticatedRequest_refreshesExpiredTokenBeforeSending() async throws {
        struct Thing: Decodable { let name: String }
        let transport = StubTransport()
        transport.responses = [
            (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)), // refresh
            (200, Data(#"{"name":"hello"}"#.utf8)), // actual request
        ]
        let store = makeStore(expired: true)
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        _ = try await client.get("things/1") as Thing

        XCTAssertEqual(transport.calls[1].request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(store.load()?.accessToken, "new-access")
        store.clear()
    }

    func test_authenticatedRequest_retriesOnceOn401ThenSucceeds() async throws {
        struct Thing: Decodable { let name: String }
        let transport = StubTransport()
        transport.responses = [
            (401, Data()), // first attempt rejected
            (200, Data(#"{"access_token":"refreshed","refresh_token":"refreshed-r","expires_in":3600}"#.utf8)), // refresh
            (200, Data(#"{"name":"hello"}"#.utf8)), // retried request
        ]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        _ = try await client.get("things/1") as Thing

        XCTAssertEqual(transport.calls.count, 3)
        store.clear()
    }

    func test_apiError_forNon401FailureStatus_throwsApiErrorWithMessage() async {
        let transport = StubTransport()
        transport.responses = [(422, Data(#"{"error":"Name can't be blank"}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        do {
            struct Thing: Decodable {}
            _ = try await client.get("things/1") as Thing
            XCTFail("expected an error")
        } catch let FreeAgentError.apiError(status, message) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(message, "Name can't be blank")
        } catch {
            XCTFail("expected FreeAgentError.apiError, got \(error)")
        }
        store.clear()
    }

    func test_post_wrapsBodyInEnvelopeKey() async throws {
        struct CreateBody: Encodable { let name: String }
        struct Created: Decodable { let name: String }
        let transport = StubTransport()
        transport.responses = [(201, Data(#"{"name":"new thing"}"#.utf8))]
        let store = makeStore()
        let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: store, transport: transport)

        _ = try await client.post("things", envelopeKey: "thing", body: CreateBody(name: "new thing")) as Created

        let sentBody = transport.calls[0].request.httpBody!
        let json = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
        XCTAssertNotNil(json["thing"])
        store.clear()
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter FreeAgentAPIClientTests`
Expected: PASS. If `test_getList_followsPaginationUntilShortPage`'s hand-built JSON is fiddly to get exactly right, replace it with `JSONSerialization.data(withJSONObject:)` built from a Swift array/dictionary instead of string concatenation — whichever is less error-prone, the assertion (101 items, 2 calls) is what matters.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeAgentKit/FreeAgentAPIClient.swift Tests/FreeAgentKitTests/FreeAgentAPIClientTests.swift
git commit -m "feat: add FreeAgentAPIClient with pagination and 401-retry"
```

---

### Task 10: FreeAgent DTOs and mapping to `Ratchet*` models

**Files:**
- Create: `Sources/FreeAgentKit/FreeAgentDTOs.swift`
- Create: `Sources/FreeAgentKit/FreeAgentModelMapping.swift`
- Create: `Tests/FreeAgentKitTests/FreeAgentModelMappingTests.swift`

**Interfaces:**
- Consumes: `RatchetClient`/`RatchetProject`/`RatchetTask`/`RatchetTimeslip` (`RatchetCore`, unchanged).
- Produces: DTOs (`FreeAgentContactDTO`, `FreeAgentProjectDTO`, `FreeAgentTaskDTO`, `FreeAgentTimeslipDTO`, `FreeAgentUserDTO`) and mapping functions Task 13 (`FreeAgentDataStore`) consumes directly:
```swift
extension FreeAgentContactDTO { func toRatchetClient(projects: [RatchetProject]) -> RatchetClient }
extension FreeAgentProjectDTO { func toRatchetProject(tasks: [RatchetTask]) -> RatchetProject }
extension FreeAgentTaskDTO { func toRatchetTask() -> RatchetTask }
extension FreeAgentTimeslipDTO { func toRatchetTimeslip() -> RatchetTimeslip }
```

- [ ] **Step 1: Create the DTOs**

`Sources/FreeAgentKit/FreeAgentDTOs.swift`:

```swift
import Foundation

/// FreeAgent addresses every resource by its full URL, e.g.
/// "https://api.sandbox.freeagent.com/v2/projects/1". Ratchet's models use
/// that URL directly as `id`, since FreeAgent's own filter/reference
/// params expect the full URI back — no bare-ID extraction/reconstruction.

public struct FreeAgentContactDTO: Codable {
    public let url: String
    public let organisationName: String?
    public let firstName: String?
    public let lastName: String?
    public let email: String?
    public let phoneNumber: String?
    public let address1: String?
    public let town: String?
    public let postcode: String?
    public let country: String?

    enum CodingKeys: String, CodingKey {
        case url
        case organisationName = "organisation_name"
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case phoneNumber = "phone_number"
        case address1, town, postcode, country
    }
}

public struct FreeAgentProjectDTO: Codable {
    public let url: String
    public let contact: String
    public let name: String
    public let status: String
    public let currency: String
    public let budget: String?
    public let budgetUnits: String?
    public let hoursPerDay: String?
    public let normalBillingRate: String?
    public let billingPeriod: String?
    public let usesProjectInvoiceSequence: Bool?
    public let contractPoReference: String?
    public let startsOn: String?
    public let endsOn: String?

    enum CodingKeys: String, CodingKey {
        case url, contact, name, status, currency
        case budget
        case budgetUnits = "budget_units"
        case hoursPerDay = "hours_per_day"
        case normalBillingRate = "normal_billing_rate"
        case billingPeriod = "billing_period"
        case usesProjectInvoiceSequence = "uses_project_invoice_sequence"
        case contractPoReference = "contract_po_reference"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
    }
}

public struct FreeAgentTaskDTO: Codable {
    public let url: String
    public let project: String
    public let name: String
    public let isBillable: Bool
    public let status: String
    public let billingRate: String?
    public let billingPeriod: String?

    enum CodingKeys: String, CodingKey {
        case url, project, name
        case isBillable = "is_billable"
        case status
        case billingRate = "billing_rate"
        case billingPeriod = "billing_period"
    }
}

public struct FreeAgentTimerDTO: Codable {
    public let running: Bool
    public let startFrom: Date

    enum CodingKeys: String, CodingKey {
        case running
        case startFrom = "start_from"
    }
}

public struct FreeAgentTimeslipDTO: Codable {
    public let url: String
    public let project: String
    public let task: String
    public let user: String
    public let datedOn: String
    public let hours: String
    public let comment: String?
    public let timer: FreeAgentTimerDTO?

    enum CodingKeys: String, CodingKey {
        case url, project, task, user
        case datedOn = "dated_on"
        case hours, comment, timer
    }
}

public struct FreeAgentUserDTO: Codable {
    public let url: String
    public let email: String
}
```

- [ ] **Step 2: Create the mapping functions**

`Sources/FreeAgentKit/FreeAgentModelMapping.swift`:

```swift
import Foundation
import RatchetCore

private let freeAgentDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

extension FreeAgentContactDTO {
    /// FreeAgent's client display name: organisation name if present,
    /// otherwise "First Last".
    var displayName: String {
        if let organisationName, !organisationName.isEmpty { return organisationName }
        return [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }

    func toRatchetClient(projects: [RatchetProject]) -> RatchetClient {
        RatchetClient(
            id: url,
            name: displayName,
            projects: projects,
            email: email,
            phoneNumber: phoneNumber,
            address1: address1,
            town: town,
            postcode: postcode,
            country: country
        )
    }
}

extension FreeAgentProjectDTO {
    func toRatchetProject(tasks: [RatchetTask]) -> RatchetProject {
        RatchetProject(
            id: url,
            name: name,
            tasks: tasks,
            status: ProjectStatus(rawValue: status) ?? .active,
            currency: currency,
            budget: budget.flatMap(Double.init) ?? 0,
            budgetUnits: budgetUnits.flatMap(BudgetUnits.init(rawValue:)) ?? .hours,
            hoursPerDay: hoursPerDay.flatMap(Double.init) ?? 8,
            normalBillingRate: normalBillingRate.flatMap(Double.init) ?? 0,
            billingPeriod: billingPeriod.flatMap(BillingPeriod.init(rawValue:)) ?? .hour,
            usesProjectInvoiceSequence: usesProjectInvoiceSequence ?? false,
            contractPoReference: contractPoReference,
            startsOn: startsOn.flatMap { freeAgentDateFormatter.date(from: $0) },
            endsOn: endsOn.flatMap { freeAgentDateFormatter.date(from: $0) }
        )
    }
}

extension FreeAgentTaskDTO {
    func toRatchetTask() -> RatchetTask {
        RatchetTask(
            id: url,
            name: name,
            isBillable: isBillable,
            status: TaskStatus(rawValue: status) ?? .active,
            billingRate: billingRate.flatMap(Double.init),
            billingPeriod: billingPeriod.flatMap(BillingPeriod.init(rawValue:))
        )
    }
}

extension FreeAgentTimeslipDTO {
    func toRatchetTimeslip() -> RatchetTimeslip {
        RatchetTimeslip(
            id: url,
            clientId: "", // filled in by FreeAgentDataStore, which knows project->client
            projectId: project,
            taskId: task,
            date: timer?.startFrom ?? freeAgentDateFormatter.date(from: datedOn) ?? Date(),
            hours: Double(hours) ?? 0,
            comment: comment
        )
    }
}
```

Note: `clientId` can't be derived from a timeslip DTO alone (FreeAgent's timeslip JSON only references `project`, not `contact`/client directly) — leave it blank here and have `FreeAgentDataStore` (Task 13) fill it in once it knows which client owns that project, by re-mapping with the resolved `clientId` rather than using this extension's output directly for timeslips that need it. Document this clearly in Task 13's code so it isn't a silent gap.

- [ ] **Step 3: Write the mapping tests**

`Tests/FreeAgentKitTests/FreeAgentModelMappingTests.swift`:

```swift
import XCTest
@testable import FreeAgentKit
import RatchetCore

final class FreeAgentModelMappingTests: XCTestCase {
    func test_contactDTO_prefersOrganisationNameOverPersonName() {
        let dto = FreeAgentContactDTO(
            url: "https://api.sandbox.freeagent.com/v2/contacts/1",
            organisationName: "Acme Ltd",
            firstName: "Jane", lastName: "Doe",
            email: nil, phoneNumber: nil, address1: nil, town: nil, postcode: nil, country: nil
        )
        let client = dto.toRatchetClient(projects: [])
        XCTAssertEqual(client.name, "Acme Ltd")
        XCTAssertEqual(client.id, "https://api.sandbox.freeagent.com/v2/contacts/1")
    }

    func test_contactDTO_fallsBackToFirstLastNameWhenNoOrganisation() {
        let dto = FreeAgentContactDTO(
            url: "https://api.sandbox.freeagent.com/v2/contacts/2",
            organisationName: nil,
            firstName: "Jane", lastName: "Doe",
            email: nil, phoneNumber: nil, address1: nil, town: nil, postcode: nil, country: nil
        )
        XCTAssertEqual(dto.toRatchetClient(projects: []).name, "Jane Doe")
    }

    func test_projectDTO_mapsStatusAndNumericFieldsWithDefaults() {
        let dto = FreeAgentProjectDTO(
            url: "https://api.sandbox.freeagent.com/v2/projects/1",
            contact: "https://api.sandbox.freeagent.com/v2/contacts/1",
            name: "Website Redesign",
            status: "Active",
            currency: "GBP",
            budget: "1000.0", budgetUnits: "Hours",
            hoursPerDay: "8.0", normalBillingRate: "50.0", billingPeriod: "hour",
            usesProjectInvoiceSequence: false, contractPoReference: nil,
            startsOn: "2026-01-01", endsOn: nil
        )
        let project = dto.toRatchetProject(tasks: [])
        XCTAssertEqual(project.status, .active)
        XCTAssertEqual(project.budget, 1000.0)
        XCTAssertEqual(project.hoursPerDay, 8.0)
        XCTAssertNotNil(project.startsOn)
        XCTAssertNil(project.endsOn)
    }

    func test_taskDTO_mapsBillingFields() {
        let dto = FreeAgentTaskDTO(
            url: "https://api.sandbox.freeagent.com/v2/tasks/1",
            project: "https://api.sandbox.freeagent.com/v2/projects/1",
            name: "Development",
            isBillable: true,
            status: "Active",
            billingRate: "75.0",
            billingPeriod: "hour"
        )
        let task = dto.toRatchetTask()
        XCTAssertEqual(task.billingRate, 75.0)
        XCTAssertEqual(task.billingPeriod, .hour)
    }

    func test_timeslipDTO_withRunningTimer_usesTimerStartFromAsDate() {
        let startFrom = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = FreeAgentTimeslipDTO(
            url: "https://api.sandbox.freeagent.com/v2/timeslips/1",
            project: "https://api.sandbox.freeagent.com/v2/projects/1",
            task: "https://api.sandbox.freeagent.com/v2/tasks/1",
            user: "https://api.sandbox.freeagent.com/v2/users/1",
            datedOn: "2023-11-14",
            hours: "0.0",
            comment: nil,
            timer: FreeAgentTimerDTO(running: true, startFrom: startFrom)
        )
        XCTAssertEqual(dto.toRatchetTimeslip().date, startFrom)
    }

    func test_timeslipDTO_withoutTimer_usesDatedOn() {
        let dto = FreeAgentTimeslipDTO(
            url: "https://api.sandbox.freeagent.com/v2/timeslips/2",
            project: "https://api.sandbox.freeagent.com/v2/projects/1",
            task: "https://api.sandbox.freeagent.com/v2/tasks/1",
            user: "https://api.sandbox.freeagent.com/v2/users/1",
            datedOn: "2023-11-14",
            hours: "1.5",
            comment: "worked on the thing",
            timer: nil
        )
        let timeslip = dto.toRatchetTimeslip()
        XCTAssertEqual(timeslip.hours, 1.5)
        XCTAssertEqual(timeslip.comment, "worked on the thing")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter FreeAgentModelMappingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeAgentKit/FreeAgentDTOs.swift Sources/FreeAgentKit/FreeAgentModelMapping.swift Tests/FreeAgentKitTests/FreeAgentModelMappingTests.swift
git commit -m "feat: add FreeAgent DTOs and mapping to Ratchet models"
```

---

### Task 11: `FreeAgentAuthenticator` — authorize URL + callback parsing + code exchange

**Files:**
- Create: `Sources/FreeAgentKit/FreeAgentAuthenticator.swift`
- Create: `Tests/FreeAgentKitTests/FreeAgentAuthenticatorTests.swift`

**Interfaces:**
- Consumes: `FreeAgentEnvironment`, `FreeAgentAPIClient.exchangeAuthorizationCode` (Tasks 7, 9), `FreeAgentSecrets` (Task 1).
- Produces:
```swift
public struct OAuthCallbackResult {
    public let code: String
    public let state: String
}
public enum OAuthCallbackParser {
    public static func parse(url: URL) -> OAuthCallbackResult?
}
public final class FreeAgentAuthenticator {
    public init(environment: FreeAgentEnvironment, apiClient: FreeAgentAPIClient)
    public func buildAuthorizeURL() -> (url: URL, state: String)
    public func handleCallback(url: URL, expectedState: String) async throws -> FreeAgentTokens
}
```
Task 12 (AppDelegate's Apple Event handler) calls `buildAuthorizeURL()` before opening the browser and `handleCallback(url:expectedState:)` when the `ratchet://` event arrives.

- [ ] **Step 1: Write `OAuthCallbackParser` (the pure, directly-testable part)**

`Sources/FreeAgentKit/FreeAgentAuthenticator.swift` (part 1):

```swift
import Foundation

public struct OAuthCallbackResult {
    public let code: String
    public let state: String
}

public enum OAuthCallbackParser {
    /// Parses "ratchet://callback?code=...&state=..." — returns nil if the
    /// URL isn't a well-formed callback (missing code or state).
    public static func parse(url: URL) -> OAuthCallbackResult? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value,
              let state = queryItems.first(where: { $0.name == "state" })?.value
        else { return nil }
        return OAuthCallbackResult(code: code, state: state)
    }
}
```

- [ ] **Step 2: Write `FreeAgentAuthenticator` (append to the same file)**

```swift
public final class FreeAgentAuthenticator {
    public static let redirectURI = "ratchet://callback"

    private let environment: FreeAgentEnvironment
    private let apiClient: FreeAgentAPIClient

    public init(environment: FreeAgentEnvironment, apiClient: FreeAgentAPIClient) {
        self.environment = environment
        self.apiClient = apiClient
    }

    /// Builds the browser URL to open, and the CSRF nonce the eventual
    /// callback's `state` must match.
    public func buildAuthorizeURL() -> (url: URL, state: String) {
        let state = UUID().uuidString
        var components = URLComponents(url: environment.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: FreeAgentSecrets.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return (components.url!, state)
    }

    /// Validates the callback URL against the nonce from `buildAuthorizeURL`,
    /// then exchanges the code for tokens.
    public func handleCallback(url: URL, expectedState: String) async throws -> FreeAgentTokens {
        guard let result = OAuthCallbackParser.parse(url: url) else {
            throw FreeAgentError.authCancelled
        }
        guard result.state == expectedState else {
            throw FreeAgentError.stateMismatch
        }
        return try await apiClient.exchangeAuthorizationCode(result.code, redirectURI: Self.redirectURI)
    }
}
```

- [ ] **Step 3: Write the tests**

`Tests/FreeAgentKitTests/FreeAgentAuthenticatorTests.swift`:

```swift
import XCTest
@testable import FreeAgentKit

final class FreeAgentAuthenticatorTests: XCTestCase {
    func test_parse_extractsCodeAndState() {
        let url = URL(string: "ratchet://callback?code=abc123&state=xyz")!
        let result = OAuthCallbackParser.parse(url: url)
        XCTAssertEqual(result?.code, "abc123")
        XCTAssertEqual(result?.state, "xyz")
    }

    func test_parse_returnsNilWhenCodeMissing() {
        let url = URL(string: "ratchet://callback?state=xyz")!
        XCTAssertNil(OAuthCallbackParser.parse(url: url))
    }

    func test_parse_returnsNilWhenStateMissing() {
        let url = URL(string: "ratchet://callback?code=abc123")!
        XCTAssertNil(OAuthCallbackParser.parse(url: url))
    }

    func test_buildAuthorizeURL_includesRedirectURIAndGeneratesUniqueState() {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)

        let (url1, state1) = authenticator.buildAuthorizeURL()
        let (_, state2) = authenticator.buildAuthorizeURL()

        XCTAssertTrue(url1.absoluteString.contains("redirect_uri=ratchet://callback") || url1.absoluteString.contains("redirect_uri=ratchet%3A%2F%2Fcallback"))
        XCTAssertNotEqual(state1, state2)
    }

    func test_handleCallback_throwsStateMismatchWhenStateDoesNotMatch() async {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)
        let callbackURL = URL(string: "ratchet://callback?code=abc&state=wrong")!

        do {
            _ = try await authenticator.handleCallback(url: callbackURL, expectedState: "expected")
            XCTFail("expected FreeAgentError.stateMismatch")
        } catch FreeAgentError.stateMismatch {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.stateMismatch, got \(error)")
        }
    }

    func test_handleCallback_throwsAuthCancelledWhenCodeMissing() async {
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: KeychainTokenStore(service: "unused-in-this-test"))
        let authenticator = FreeAgentAuthenticator(environment: .sandbox, apiClient: apiClient)
        let callbackURL = URL(string: "ratchet://callback?state=expected")!

        do {
            _ = try await authenticator.handleCallback(url: callbackURL, expectedState: "expected")
            XCTFail("expected FreeAgentError.authCancelled")
        } catch FreeAgentError.authCancelled {
            // expected
        } catch {
            XCTFail("expected FreeAgentError.authCancelled, got \(error)")
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter FreeAgentAuthenticatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeAgentKit/FreeAgentAuthenticator.swift Tests/FreeAgentKitTests/FreeAgentAuthenticatorTests.swift
git commit -m "feat: add FreeAgentAuthenticator (authorize URL, callback parsing, code exchange)"
```

---

### Task 12: Wire the `ratchet://` Apple Event handler into `AppDelegate`

**Files:**
- Create: `Sources/Ratchet/URLSchemeHandler.swift`
- Modify: `Sources/Ratchet/AppDelegate.swift`

**Interfaces:**
- Consumes: `FreeAgentAuthenticator.handleCallback(url:expectedState:)` (Task 11).
- Produces: `URLSchemeHandler` — a small class other code (Task 14's login flow) hands a pending `(url, expectedState)` continuation to, and which resolves it when the OS delivers the `ratchet://` event.

```swift
public final class URLSchemeHandler {
    public init()
    public func register()
    /// Suspends until a ratchet:// URL arrives (or the timeout elapses), then returns it.
    public func waitForCallback(timeout: TimeInterval) async throws -> URL
}
```

- [ ] **Step 1: Write `URLSchemeHandler`**

`Sources/Ratchet/URLSchemeHandler.swift`:

```swift
// Sources/Ratchet/URLSchemeHandler.swift
import AppKit
import FreeAgentKit

/// Registers for the ratchet:// custom URL scheme via the classic
/// NSAppleEventManager mechanism (the reliable way to receive a
/// custom-scheme open on macOS, independent of full app-lifecycle timing)
/// and exposes an async "wait for the next callback URL" API.
public final class URLSchemeHandler {
    private var continuation: CheckedContinuation<URL, Error>?

    public init() {}

    public func register() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    public func waitForCallback(timeout: TimeInterval) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(throwing: FreeAgentError.authTimedOut)
            }
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        continuation?.resume(returning: url)
        continuation = nil
    }
}
```

- [ ] **Step 2: Register the handler in `AppDelegate`**

`Sources/Ratchet/AppDelegate.swift` — add `applicationWillFinishLaunching` and a stored `urlSchemeHandler`:

```swift
// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore
import FreeAgentKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    let urlSchemeHandler = URLSchemeHandler()

    func applicationWillFinishLaunching(_ notification: Notification) {
        urlSchemeHandler.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dataStore = FakeDataStore.seeded()
        let appState = AppState()
        statusItemController = StatusItemController(appState: appState, dataStore: dataStore)
    }
}
```

(This task only wires the *registration* and *waiting* mechanism — `applicationDidFinishLaunching` still uses `FakeDataStore` for now; Task 14 swaps in the real store and calls `urlSchemeHandler.waitForCallback` from the login flow.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Manual verification (requires Task 6's bundling script and real credentials — do this once Secrets.swift has real values from the registration step)**

```bash
scripts/build-app.sh debug
open .build/Ratchet.app
open 'ratchet://callback?code=test123&state=test'
```
Expected: the running app doesn't crash and (once Task 14 wires the login flow to actually call `waitForCallback`) would resolve with that URL. Since Task 14 hasn't wired the caller yet, this step just confirms the OS routes the custom scheme to the app at all — check Console.app or add a temporary `print(url)` inside `handleGetURLEvent` to confirm receipt, then remove the print before committing.

- [ ] **Step 5: Commit**

```bash
git add Sources/Ratchet/URLSchemeHandler.swift Sources/Ratchet/AppDelegate.swift
git commit -m "feat: register ratchet:// URL scheme handler in AppDelegate"
```

---

### Task 13: `FreeAgentDataStore` — the real `DataStore` conformance

**Files:**
- Create: `Sources/FreeAgentKit/FreeAgentDataStore.swift`
- Create: `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`

**Interfaces:**
- Consumes: `DataStore` protocol (`RatchetCore`, Task 2), `FreeAgentAPIClient` (Task 9), DTOs + mapping (Task 10).
- Produces:
```swift
public final class FreeAgentDataStore: DataStore {
    public init(apiClient: FreeAgentAPIClient)
    public var clients: [RatchetClient] { get }
    public var accountEmail: String { get }
    public var timeslips: [RatchetTimeslip] { get }
    public var lastRefreshedAt: Date? { get }
    // ... full DataStore conformance ...
    public var currentRunningTimeslip: RatchetTimeslip? { get } // consumed by Task 14's launch restore logic
}
```

- [ ] **Step 1: Write `FreeAgentDataStore`**

`Sources/FreeAgentKit/FreeAgentDataStore.swift`:

```swift
import Foundation
import RatchetCore

public final class FreeAgentDataStore: DataStore {
    public private(set) var clients: [RatchetClient] = []
    public private(set) var accountEmail: String = ""
    public private(set) var timeslips: [RatchetTimeslip] = []
    public private(set) var lastRefreshedAt: Date?
    public private(set) var currentRunningTimeslip: RatchetTimeslip?

    private let apiClient: FreeAgentAPIClient
    private let clock: () -> Date
    /// project URL -> client URL, so timeslip DTOs (which only know their
    /// project) can be assigned the right clientId.
    private var projectToClientId: [String: String] = [:]
    private var currentUserURL: String = ""

    public init(apiClient: FreeAgentAPIClient, clock: @escaping () -> Date = Date.init) {
        self.apiClient = apiClient
        self.clock = clock
    }

    public func refresh() async throws {
        let user: FreeAgentUserDTO = try await apiClient.get("users/me")
        accountEmail = user.email
        currentUserURL = user.url

        let contacts: [FreeAgentContactDTO] = try await apiClient.getList("contacts", listKey: "contacts")
        let projects: [FreeAgentProjectDTO] = try await apiClient.getList("projects", listKey: "projects")
        let tasks: [FreeAgentTaskDTO] = try await apiClient.getList("tasks", listKey: "tasks")

        projectToClientId = Dictionary(uniqueKeysWithValues: projects.map { ($0.url, $0.contact) })

        let tasksByProject = Dictionary(grouping: tasks, by: \.project)
        let projectsByContact = Dictionary(grouping: projects, by: \.contact)

        clients = contacts.map { contact in
            let contactProjects = (projectsByContact[contact.url] ?? []).map { project in
                let projectTasks = (tasksByProject[project.url] ?? []).map { $0.toRatchetTask() }
                return project.toRatchetProject(tasks: projectTasks)
            }
            return contact.toRatchetClient(projects: contactProjects)
        }

        let today = todayString()
        let todaysTimeslips: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "from_date", value: today),
                URLQueryItem(name: "to_date", value: today),
                URLQueryItem(name: "user", value: currentUserURL),
            ], listKey: "timeslips"
        )
        timeslips = todaysTimeslips.map { resolvedTimeslip($0) }

        let runningTimeslips: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "view", value: "running"),
                URLQueryItem(name: "user", value: currentUserURL),
            ], listKey: "timeslips"
        )
        currentRunningTimeslip = runningTimeslips.first.map { resolvedTimeslip($0) }

        lastRefreshedAt = clock()
    }

    public func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip {
        let today = todayString()
        let existing: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "task", value: taskId),
                URLQueryItem(name: "project", value: projectId),
                URLQueryItem(name: "from_date", value: today),
                URLQueryItem(name: "to_date", value: today),
                URLQueryItem(name: "user", value: currentUserURL),
            ], listKey: "timeslips"
        )

        let timeslipURL: String
        if let found = existing.first {
            timeslipURL = found.url
        } else {
            struct CreateTimeslipBody: Encodable {
                let project: String
                let task: String
                let user: String
                let dated_on: String
                let hours: String
            }
            let created: FreeAgentTimeslipDTO = try await apiClient.post(
                "timeslips", envelopeKey: "timeslip",
                body: CreateTimeslipBody(project: projectId, task: taskId, user: currentUserURL, dated_on: today, hours: "0.0")
            )
            timeslipURL = created.url
        }

        struct EmptyBody: Encodable {}
        let started: FreeAgentTimeslipDTO = try await apiClient.post(
            "\(timeslipURL)/timer", envelopeKey: "timer", body: EmptyBody()
        )
        let resolved = resolvedTimeslip(started, clientId: clientId)
        currentRunningTimeslip = resolved
        return resolved
    }

    public func stopTimer() async throws -> RatchetTimeslip? {
        guard let running = currentRunningTimeslip else { return nil }
        try await apiClient.delete("\(running.id)/timer")
        currentRunningTimeslip = nil
        return running
    }

    public func addClient(
        name: String, email: String?, phoneNumber: String?, address1: String?,
        town: String?, postcode: String?, country: String?
    ) async throws -> RatchetClient {
        struct CreateContactBody: Encodable {
            let organisation_name: String?
            let email: String?
            let phone_number: String?
            let address1: String?
            let town: String?
            let postcode: String?
            let country: String?
        }
        let created: FreeAgentContactDTO = try await apiClient.post(
            "contacts", envelopeKey: "contact",
            body: CreateContactBody(
                organisation_name: name, email: email, phone_number: phoneNumber,
                address1: address1, town: town, postcode: postcode, country: country
            )
        )
        let client = created.toRatchetClient(projects: [])
        clients.append(client)
        return client
    }

    public func addProject(
        name: String, clientId: String, status: ProjectStatus, currency: String,
        budget: Double, budgetUnits: BudgetUnits, hoursPerDay: Double,
        normalBillingRate: Double, billingPeriod: BillingPeriod,
        usesProjectInvoiceSequence: Bool, contractPoReference: String?,
        startsOn: Date?, endsOn: Date?
    ) async throws -> RatchetProject {
        struct CreateProjectBody: Encodable {
            let contact: String
            let name: String
            let status: String
            let currency: String
            let budget: String
            let budget_units: String
            let hours_per_day: String
            let normal_billing_rate: String
            let billing_period: String
            let uses_project_invoice_sequence: Bool
            let contract_po_reference: String?
        }
        let created: FreeAgentProjectDTO = try await apiClient.post(
            "projects", envelopeKey: "project",
            body: CreateProjectBody(
                contact: clientId, name: name, status: status.rawValue, currency: currency,
                budget: String(budget), budget_units: budgetUnits.rawValue,
                hours_per_day: String(hoursPerDay), normal_billing_rate: String(normalBillingRate),
                billing_period: billingPeriod.rawValue, uses_project_invoice_sequence: usesProjectInvoiceSequence,
                contract_po_reference: contractPoReference
            )
        )
        projectToClientId[created.url] = clientId
        let project = created.toRatchetProject(tasks: [])
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }) else { throw DataStoreError.notFound }
        clients[clientIndex] = withAppendedProject(clients[clientIndex], project)
        return project
    }

    public func addTask(
        name: String, projectId: String, clientId: String, isBillable: Bool,
        status: TaskStatus, billingRate: Double?, billingPeriod: BillingPeriod?
    ) async throws -> RatchetTask {
        struct CreateTaskBody: Encodable {
            let name: String
            let is_billable: Bool
            let status: String
            let billing_rate: String?
            let billing_period: String?
        }
        let created: FreeAgentTaskDTO = try await apiClient.post(
            "tasks", envelopeKey: "task",
            query: [URLQueryItem(name: "project", value: projectId)],
            body: CreateTaskBody(
                name: name, is_billable: isBillable, status: status.rawValue,
                billing_rate: billingRate.map(String.init), billing_period: billingPeriod?.rawValue
            )
        )
        let task = created.toRatchetTask()
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientId }),
              let projectIndex = clients[clientIndex].projects.firstIndex(where: { $0.id == projectId })
        else { throw DataStoreError.notFound }
        clients[clientIndex] = withAppendedTask(clients[clientIndex], projectIndex: projectIndex, task: task)
        return task
    }

    public func logTime(
        taskId: String, projectId: String, clientId: String, date: Date, hours: Double, comment: String?
    ) async throws -> RatchetTimeslip {
        struct CreateTimeslipBody: Encodable {
            let project: String
            let task: String
            let user: String
            let dated_on: String
            let hours: String
            let comment: String?
        }
        let created: FreeAgentTimeslipDTO = try await apiClient.post(
            "timeslips", envelopeKey: "timeslip",
            body: CreateTimeslipBody(
                project: projectId, task: taskId, user: currentUserURL,
                dated_on: dateString(date), hours: String(hours), comment: comment
            )
        )
        let resolved = resolvedTimeslip(created, clientId: clientId)
        timeslips.append(resolved)
        return resolved
    }

    // MARK: - Private helpers

    private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, clientId: String? = nil) -> RatchetTimeslip {
        let resolvedClientId = clientId ?? projectToClientId[dto.project] ?? ""
        let mapped = dto.toRatchetTimeslip()
        return RatchetTimeslip(
            id: mapped.id, clientId: resolvedClientId, projectId: mapped.projectId,
            taskId: mapped.taskId, date: mapped.date, hours: mapped.hours, comment: mapped.comment
        )
    }

    private func withAppendedProject(_ client: RatchetClient, _ project: RatchetProject) -> RatchetClient {
        RatchetClient(
            id: client.id, name: client.name, projects: client.projects + [project],
            email: client.email, phoneNumber: client.phoneNumber, address1: client.address1,
            town: client.town, postcode: client.postcode, country: client.country
        )
    }

    private func withAppendedTask(_ client: RatchetClient, projectIndex: Int, task: RatchetTask) -> RatchetClient {
        var projects = client.projects
        let existing = projects[projectIndex]
        projects[projectIndex] = RatchetProject(
            id: existing.id, name: existing.name, tasks: existing.tasks + [task],
            status: existing.status, currency: existing.currency, budget: existing.budget,
            budgetUnits: existing.budgetUnits, hoursPerDay: existing.hoursPerDay,
            normalBillingRate: existing.normalBillingRate, billingPeriod: existing.billingPeriod,
            usesProjectInvoiceSequence: existing.usesProjectInvoiceSequence,
            contractPoReference: existing.contractPoReference, startsOn: existing.startsOn, endsOn: existing.endsOn
        )
        return RatchetClient(
            id: client.id, name: client.name, projects: projects,
            email: client.email, phoneNumber: client.phoneNumber, address1: client.address1,
            town: client.town, postcode: client.postcode, country: client.country
        )
    }

    private func todayString() -> String { dateString(clock()) }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Write the tests using the stub transport from Task 9**

`Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`:

```swift
import XCTest
@testable import FreeAgentKit
import RatchetCore

private final class StubTransport: FreeAgentTransport {
    var responsesByPathSubstring: [(match: String, status: Int, body: Data)] = []
    var calls: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(request)
        let path = request.url!.absoluteString
        guard let entry = responsesByPathSubstring.first(where: { path.contains($0.match) }) else {
            fatalError("No stubbed response matches \(path)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: entry.status, httpVersion: nil, headerFields: nil)!
        return (entry.body, response)
    }
}

final class FreeAgentDataStoreTests: XCTestCase {
    private func makeStore(transport: StubTransport) -> (FreeAgentDataStore, KeychainTokenStore) {
        let tokenStore = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
        tokenStore.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600)))
        let apiClient = FreeAgentAPIClient(environment: .sandbox, tokenStore: tokenStore, transport: transport)
        return (FreeAgentDataStore(apiClient: apiClient), tokenStore)
    }

    func test_refresh_assemblesClientProjectTaskTree() async throws {
        let transport = StubTransport()
        transport.responsesByPathSubstring = [
            (match: "users/me", status: 200, body: Data(#"{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}"#.utf8)),
            (match: "contacts", status: 200, body: Data(#"{"contacts":[{"url":"https://api.sandbox.freeagent.com/v2/contacts/1","organisation_name":"Acme","first_name":null,"last_name":null,"email":null,"phone_number":null,"address1":null,"town":null,"postcode":null,"country":null}]}"#.utf8)),
            (match: "projects", status: 200, body: Data(#"{"projects":[{"url":"https://api.sandbox.freeagent.com/v2/projects/1","contact":"https://api.sandbox.freeagent.com/v2/contacts/1","name":"Website Redesign","status":"Active","currency":"GBP","budget":"0","budget_units":"Hours","hours_per_day":"8","normal_billing_rate":"0","billing_period":"hour","uses_project_invoice_sequence":false,"contract_po_reference":null,"starts_on":null,"ends_on":null}]}"#.utf8)),
            (match: "tasks", status: 200, body: Data(#"{"tasks":[{"url":"https://api.sandbox.freeagent.com/v2/tasks/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","name":"Development","is_billable":true,"status":"Active","billing_rate":null,"billing_period":null}]}"#.utf8)),
            (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        ]
        let (store, tokenStore) = makeStore(transport: transport)

        try await store.refresh()

        XCTAssertEqual(store.accountEmail, "al@example.com")
        XCTAssertEqual(store.clients.map(\.name), ["Acme"])
        XCTAssertEqual(store.clients[0].projects.map(\.name), ["Website Redesign"])
        XCTAssertEqual(store.clients[0].projects[0].tasks.map(\.name), ["Development"])
        tokenStore.clear()
    }
}
```

Note: the `"timeslips?"` match string is deliberately loose — it matches both the today's-timeslips call and the running-timer call, both of which return an empty list here, keeping this first test focused on the client/project/task assembly. Task 13's implementer should add further tests (in the same file) for `startTimer` finding-vs-creating a timeslip and `stopTimer`, following the same stub-transport pattern — matching on distinctive substrings (e.g. `"view=running"` vs a plain `from_date`/`to_date` call) to give each stubbed call the right canned response, extending `responsesByPathSubstring` as needed per test.

- [ ] **Step 3: Run the tests**

Run: `swift test --filter FreeAgentDataStoreTests`
Expected: PASS.

- [ ] **Step 4: Build the whole package**

Run: `swift build && swift test`
Expected: everything builds; all tests across `RatchetCoreTests` and `FreeAgentKitTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeAgentKit/FreeAgentDataStore.swift Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift
git commit -m "feat: add FreeAgentDataStore conforming to DataStore"
```

---

### Task 14: Final `AppDelegate` wiring — real login, launch restore, log out

**Files:**
- Modify: `Sources/Ratchet/AppDelegate.swift`
- Modify: `Sources/RatchetCore/MenuActions.swift` (no signature change needed — `logIn`/`logOut` are already `() -> Void`; this task changes what `StatusItemController` passes in, not the type)
- Modify: `Sources/RatchetCore/StatusItemController.swift` (the `logIn`/`logOut` closures need to call injected async hooks)

**Interfaces:**
- Consumes: everything from Tasks 8–13 (`KeychainTokenStore`, `FreeAgentAuthenticator`, `FreeAgentDataStore`, `URLSchemeHandler`).
- This is the integration point — no new public interface, just wiring.

Since `MenuActions.logIn`/`logOut` are synchronous `() -> Void` closures but logging in now needs to open a browser, wait for a callback, and exchange a code (all async, all fallible), `StatusItemController` needs a way to run that async work and report failure. Rather than changing `MenuActions`' shape (which would ripple into every test file that constructs a `MenuActions`), give `StatusItemController` an injectable async login hook at `init` time, defaulting to a no-op for tests that don't care about it.

- [ ] **Step 1: Add an injectable login hook to `StatusItemController`**

In `Sources/RatchetCore/StatusItemController.swift`, add a stored property and update `init`:

```swift
    public typealias LoginHandler = () async throws -> Void

    private let performLogin: LoginHandler

    public init(
        appState: AppState,
        dataStore: DataStore,
        statusBar: NSStatusBar = .system,
        performLogin: @escaping LoginHandler = {}
    ) {
        self.appState = appState
        self.dataStore = dataStore
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        self.performLogin = performLogin
        appState.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }
```

Update the `logIn` closure inside `actions`:

```swift
        logIn: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.performLogin()
                    self.appState.logIn()
                    try await self.dataStore.refresh()
                    self.rebuild()
                } catch {
                    self.presentAPIError(error, action: "log in")
                }
            }
        },
```

- [ ] **Step 2: Verify existing `StatusItemControllerTests` still compile and pass unchanged**

Run: `swift test --filter StatusItemControllerTests`
Expected: PASS — both existing tests construct `StatusItemController(appState:dataStore:)` without `performLogin`, which now defaults to a no-op async closure; behavior is unchanged for them (`test_stateChange_rebuildsMenu` calls `appState.logIn()` directly, not through the menu action, so it's unaffected).

- [ ] **Step 3: Wire `AppDelegate` end to end**

Replace `Sources/Ratchet/AppDelegate.swift`:

```swift
// Sources/Ratchet/AppDelegate.swift
import AppKit
import RatchetCore
import FreeAgentKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let urlSchemeHandler = URLSchemeHandler()
    private let tokenStore = KeychainTokenStore()
    private let environment: FreeAgentEnvironment = .sandbox

    func applicationWillFinishLaunching(_ notification: Notification) {
        urlSchemeHandler.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let apiClient = FreeAgentAPIClient(environment: environment, tokenStore: tokenStore)
        let authenticator = FreeAgentAuthenticator(environment: environment, apiClient: apiClient)
        let dataStore = FreeAgentDataStore(apiClient: apiClient)
        let appState = AppState()

        let controller = StatusItemController(
            appState: appState,
            dataStore: dataStore,
            performLogin: { [urlSchemeHandler, tokenStore] in
                let (authorizeURL, expectedState) = authenticator.buildAuthorizeURL()
                NSWorkspace.shared.open(authorizeURL)
                let callbackURL = try await urlSchemeHandler.waitForCallback(timeout: 180)
                let tokens = try await authenticator.handleCallback(url: callbackURL, expectedState: expectedState)
                tokenStore.save(tokens)
            }
        )
        statusItemController = controller

        if tokenStore.load() != nil {
            appState.logIn()
            Task { @MainActor in
                do {
                    try await dataStore.refresh()
                    if let running = dataStore.currentRunningTimeslip,
                       let client = dataStore.clients.first(where: { $0.id == running.clientId }),
                       let project = client.projects.first(where: { $0.id == running.projectId }),
                       let task = project.tasks.first(where: { $0.id == running.taskId }) {
                        let ref = TrackedTaskRef(
                            clientId: client.id, clientName: client.name,
                            projectId: project.id, projectName: project.name,
                            taskId: task.id, taskName: task.name
                        )
                        appState.startTracking(ref, startedAt: running.date)
                    }
                } catch {
                    // Launch-time refresh failure isn't fatal — the user can
                    // trigger "Refresh projects & tasks" manually; surfacing
                    // an alert before the menu bar item is even visible/clicked
                    // would be a jarring first impression on every launch
                    // where e.g. Wi-Fi hasn't connected yet.
                }
            }
        }
    }
}
```

- [ ] **Step 4: Make `logOut` clear the Keychain**

`MenuActions.logOut` is invoked from `AppState.logOut()` via the closure `{ [weak self] in self?.appState.logOut() }` in `StatusItemController`. Add Keychain clearing alongside it — update that closure in `StatusItemController.swift`'s `actions`:

```swift
        logOut: { [weak self] in
            self?.appState.logOut()
            self?.onLogOut?()
        },
```

Add a new public hook, mirroring `performLogin`'s pattern:

```swift
    public var onLogOut: (() -> Void)?
```

And in `AppDelegate.applicationDidFinishLaunching`, after constructing `controller`:

```swift
        controller.onLogOut = { [tokenStore] in
            tokenStore.clear()
        }
```

- [ ] **Step 5: Build everything**

Run: `swift build && swift test`
Expected: builds clean, all tests pass (nothing in this task touches test-covered logic beyond the `performLogin` default already verified in Step 2).

- [ ] **Step 6: Manual end-to-end verification (requires real Client ID/Secret in `Secrets.swift` from the registration step)**

```bash
scripts/build-app.sh debug
open .build/Ratchet.app
```
Click the menu bar clock icon → "Log in with browser" → complete the FreeAgent sandbox login in the browser that opens → confirm the browser tab shows FreeAgent's own post-authorization page (or redirects back) and the Ratchet menu now shows real sandbox clients/projects/tasks instead of "Acme"/"Other Co". Start tracking a real task, confirm the FreeAgent sandbox web UI (in the browser) shows a running timer on that task. Stop tracking, confirm it stops there too. Quit and relaunch Ratchet, confirm it skips the logged-out screen and restores state.

- [ ] **Step 7: Commit**

```bash
git add Sources/Ratchet/AppDelegate.swift Sources/RatchetCore/StatusItemController.swift
git commit -m "feat: wire real FreeAgent login, launch restore, and logout into AppDelegate"
```

---

## Post-plan cleanup (not a task — a reminder)

Task 1 committed a real (placeholder-valued) `Secrets.swift`-derived build config indirectly by copying the example — but `Secrets.swift` itself is gitignored, so nothing sensitive lands in git as long as `.gitignore`'s entry from Task 1 Step 5 is in place before any `git add` in later tasks. Double check `git status` never shows `Sources/FreeAgentKit/Secrets.swift` as trackable after Task 1.
