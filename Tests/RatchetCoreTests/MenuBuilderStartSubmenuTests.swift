import XCTest
import AppKit
@testable import RatchetCore

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class MenuBuilderStartSubmenuTests: XCTestCase {
    private func noopActions() -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
    }

    func test_clientsLevel_listsClientsWithSubmenus() {
        let menu = MenuBuilder.buildStartSubmenu(dataStore: FakeDataStore.seeded(), actions: noopActions())
        XCTAssertEqual(menu.items.map(\.title), ["Acme", "Other Co", "", "Add client…"])
        XCTAssertNotNil(menu.items[0].submenu)
        XCTAssertTrue(menu.items[2].isSeparatorItem)
    }

    func test_projectsLevel_listsProjectsWithSubmenus() {
        let store = FakeDataStore.seeded()
        let acme = store.clients[0]
        let menu = MenuBuilder.buildStartSubmenu(dataStore: store, actions: noopActions())
        let projectsMenu = menu.items[0].submenu!

        XCTAssertEqual(projectsMenu.items.map(\.title), acme.projects.map(\.name) + ["", "Add project…"])
        XCTAssertNotNil(projectsMenu.items[0].submenu)
        XCTAssertTrue(projectsMenu.items[2].isSeparatorItem)
    }

    func test_projectsLevel_clientWithNoProjects_showsDisabledPlaceholder() {
        let store = FakeDataStore.seeded()
        let menu = MenuBuilder.buildStartSubmenu(dataStore: store, actions: noopActions())
        let otherCoMenu = menu.items[1].submenu!

        XCTAssertEqual(otherCoMenu.items.map(\.title), ["No projects", "", "Add project…"])
        XCTAssertFalse(otherCoMenu.items[0].isEnabled)
    }

    func test_clientsLevel_noClients_showsDisabledPlaceholder() {
        let store = FakeDataStore(clients: [], accountEmail: "al@example.com")
        let menu = MenuBuilder.buildStartSubmenu(dataStore: store, actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), ["No clients", "", "Add client…"])
        XCTAssertFalse(menu.items[0].isEnabled)
    }

    func test_clickingAddClient_invokesAddClientAction() {
        var addClientCalled = false
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: { addClientCalled = true }, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
        let menu = MenuBuilder.buildStartSubmenu(dataStore: FakeDataStore.seeded(), actions: actions)
        let addClientItem = menu.items[3] as! ClosureMenuItem

        _ = addClientItem.target?.perform(addClientItem.action, with: addClientItem)

        XCTAssertTrue(addClientCalled)
    }

    func test_clickingAddProject_invokesAddProjectActionWithClientId() {
        var addedClientId: String?
        let actions = MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { clientId in addedClientId = clientId }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
        )
        let menu = MenuBuilder.buildStartSubmenu(dataStore: FakeDataStore.seeded(), actions: actions)
        let projectsMenu = menu.items[0].submenu!
        let addProjectItem = projectsMenu.items[3] as! ClosureMenuItem

        _ = addProjectItem.target?.perform(addProjectItem.action, with: addProjectItem)

        XCTAssertEqual(addedClientId, "client-1")
    }

    func test_tasksLevel_projectWithNoTasks_showsDisabledPlaceholderAboveNewTask() {
        let emptyProject = RatchetProject(id: "proj-empty", name: "Empty Project", tasks: [])
        let client = RatchetClient(id: "client-empty", name: "Empty Client", projects: [emptyProject])
        let store = FakeDataStore(clients: [client], accountEmail: "al@example.com")
        let menu = MenuBuilder.buildStartSubmenu(dataStore: store, actions: noopActions())
        let tasksMenu = menu.items[0].submenu!.items[0].submenu!

        XCTAssertEqual(tasksMenu.items.map(\.title), ["No tasks", "", "New task…"])
        XCTAssertFalse(tasksMenu.items[0].isEnabled)
        XCTAssertTrue(tasksMenu.items[1].isSeparatorItem)
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
            logIn: {}, logOut: {}, startTracking: { started = $0 }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
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
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { clientId, projectId in addedClientId = clientId; addedProjectId = projectId },
            addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in }, logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in }, editTimeEntry: { _ in }, quit: {}
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
