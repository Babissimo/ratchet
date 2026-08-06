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
