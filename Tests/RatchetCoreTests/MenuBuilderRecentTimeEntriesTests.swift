// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import AppKit
@testable import RatchetCore

// Exercises @MainActor-isolated types (see DataStore's isolation), so the whole case is pinned
// to the main actor rather than annotating every test method.
@MainActor
final class MenuBuilderRecentTimeEntriesTests: XCTestCase {
    private func noopActions(editTimeEntry: @escaping (RatchetTimeslip) -> Void = { _ in }) -> MenuActions {
        MenuActions(
            logIn: {}, logOut: {}, startTracking: { _ in }, stopTracking: {}, switchTask: { _ in },
            refresh: {}, toggleLaunchAtLogin: {}, openFreeAgent: {},
            addTask: { _, _ in }, addClient: {}, addProject: { _ in }, logPastTime: { _, _, _ in },
            logPastTimeForNewTask: { _, _ in }, switchToNewTask: { _, _ in },
            editTimeEntry: editTimeEntry, quit: {}
        )
    }

    func test_headers_labelEachSectionUnbilledFirst() {
        let store = FakeDataStore.seeded()
        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: store, actions: noopActions())

        // Both sections are empty here, so this also pins the header positions: index 0 starts
        // "Unbilled", and whatever follows its one "(empty)" row starts "Invoiced".
        XCTAssertEqual(menu.items[0].title, "Unbilled")
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(menu.items[2].title, "Invoiced")
        XCTAssertFalse(menu.items[2].isEnabled)
    }

    func test_noHistory_showsEmptyPlaceholderInBothSections() {
        let store = FakeDataStore.seeded()
        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: store, actions: noopActions())

        XCTAssertEqual(menu.items.map(\.title), ["Unbilled", "(empty)", "Invoiced", "(empty)"])
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertFalse(menu.items[3].isEnabled)
    }

    func test_excludesTheCurrentlyRunningEntry() {
        let dataStore = FakeDataStore.seeded()
        let stopped = RatchetTimeslip(
            id: "timeslip-stopped", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: Date(timeIntervalSince1970: 1_700_000_000), hours: 2.5
        )
        let running = RatchetTimeslip(
            id: "timeslip-running", clientId: "client-1", projectId: "proj-1", taskId: "task-2",
            date: Date(timeIntervalSince1970: 1_700_086_400), hours: 1.0
        )
        dataStore.seedTimeslips([stopped, running], runningId: running.id)

        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: dataStore, actions: noopActions())

        // Only the stopped entry appears; the running one is excluded outright rather than shown
        // with its stale, paused-at duration.
        XCTAssertEqual(menu.items[0].title, "Unbilled")
        XCTAssertTrue(menu.items[1].title.hasPrefix("Acme · Website Redesign · Development · 2:30 · "))
        XCTAssertEqual(menu.items[2].title, "Invoiced")
        XCTAssertEqual(menu.items[3].title, "(empty)")
        XCTAssertFalse(menu.items.contains { $0.title.contains("Design") })
    }

    func test_noRunningEntry_showsAllRecentEntriesAsUnbilled() {
        let dataStore = FakeDataStore.seeded()
        let entry = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: Date(timeIntervalSince1970: 1_700_000_000), hours: 2.5
        )
        dataStore.seedTimeslips([entry])

        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: dataStore, actions: noopActions())

        XCTAssertTrue(menu.items[1].title.hasPrefix("Acme · Website Redesign · Development · 2:30 · "))
        XCTAssertEqual(menu.items[3].title, "(empty)")
    }

    func test_unbilledEntries_areClickableAndSortedNewestFirst() {
        let older = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: CalendarDay.day(from: "2026-08-10")!, hours: 1.5, comment: nil
        )
        let newer = RatchetTimeslip(
            id: "timeslip-2", clientId: "client-1", projectId: "proj-2", taskId: "task-3",
            date: CalendarDay.day(from: "2026-08-12")!, hours: 2, comment: "Kickoff call"
        )
        let store = FakeDataStore.seeded(timeslips: [older, newer])
        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: store, actions: noopActions())

        let unbilledRows = [menu.items[1], menu.items[2]]
        // Every row is a live click target, not the old `disabledItem` placeholder — the whole
        // point of this feature is that these rows are no longer inert.
        for item in unbilledRows {
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(item is ClosureMenuItem)
        }
        // Date rendering itself (locale/format) is CalendarDay's job and covered by its own
        // tests; here just pin the path/duration prefix and that the two entries land in the
        // right (newest-first) order.
        XCTAssertTrue(unbilledRows[0].title.hasPrefix("Acme · Q3 Retainer · Copywriting · 2:00 · "))
        XCTAssertTrue(unbilledRows[1].title.hasPrefix("Acme · Website Redesign · Development · 1:30 · "))
    }

    func test_clickingUnbilledEntry_invokesEditTimeEntryWithThatEntry() {
        let entry = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: CalendarDay.day(from: "2026-08-10")!, hours: 1.5, comment: "Bug fixes"
        )
        var edited: RatchetTimeslip?
        let store = FakeDataStore.seeded(timeslips: [entry])
        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: store, actions: noopActions(editTimeEntry: { edited = $0 }))

        let item = menu.items[1] as! ClosureMenuItem
        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(edited, entry)
    }

    func test_entryForUnknownTask_showsUnknownTaskFallback() {
        let entry = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-missing",
            date: CalendarDay.day(from: "2026-08-10")!, hours: 1, comment: nil
        )
        let store = FakeDataStore.seeded(timeslips: [entry])
        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: store, actions: noopActions())

        XCTAssertTrue(menu.items[1].title.hasPrefix("Acme · Website Redesign · Unknown task · 1:00 · "))
    }

    func test_invoicedEntries_appearUnderInvoicedHeaderAndAreNotEditable() {
        let entry = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: CalendarDay.day(from: "2026-08-10")!, hours: 1.5, comment: nil, isInvoiced: true
        )
        var editCalled = false
        let store = FakeDataStore.seeded(timeslips: [entry])
        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: store, actions: noopActions(editTimeEntry: { _ in editCalled = true }))

        // Unbilled section is empty; the invoiced entry lands after the "Invoiced" header.
        XCTAssertEqual(menu.items[1].title, "(empty)")
        XCTAssertEqual(menu.items[2].title, "Invoiced")
        let invoicedRow = menu.items[3]
        XCTAssertTrue(invoicedRow.title.hasPrefix("Acme · Website Redesign · Development · 1:30 · "))
        // Disabled, not a click target — FreeAgent has already closed this entry off, so there's
        // nothing "Recent time entries" can do about it.
        XCTAssertFalse(invoicedRow.isEnabled)
        XCTAssertFalse(invoicedRow is ClosureMenuItem)

        editCalled = false
        _ = invoicedRow.target?.perform(invoicedRow.action, with: invoicedRow)
        XCTAssertFalse(editCalled)
    }

    func test_mixOfUnbilledAndInvoiced_splitsAcrossBothSections() {
        let unbilled = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            date: CalendarDay.day(from: "2026-08-10")!, hours: 1, isInvoiced: false
        )
        let invoiced = RatchetTimeslip(
            id: "timeslip-2", clientId: "client-1", projectId: "proj-1", taskId: "task-2",
            date: CalendarDay.day(from: "2026-08-11")!, hours: 2, isInvoiced: true
        )
        let store = FakeDataStore.seeded(timeslips: [unbilled, invoiced])
        let menu = MenuBuilder.buildRecentTimeEntriesSubmenu(dataStore: store, actions: noopActions())

        XCTAssertEqual(menu.items[0].title, "Unbilled")
        XCTAssertTrue(menu.items[1].title.hasPrefix("Acme · Website Redesign · Development · 1:00 · "))
        XCTAssertEqual(menu.items[2].title, "Invoiced")
        XCTAssertTrue(menu.items[3].title.hasPrefix("Acme · Website Redesign · Design · 2:00 · "))
    }
}
