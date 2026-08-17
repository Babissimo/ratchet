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

    func test_startTracking_withExplicitStartedAt_usesThatInstantNotClock() {
        let clockDate = Date(timeIntervalSince1970: 2_000_000_000)
        let explicitStart = Date(timeIntervalSince1970: 1_000_000_000)
        let state = AppState(clock: { clockDate })

        state.logIn()
        state.startTracking(sampleTask, startedAt: explicitStart)

        XCTAssertEqual(state.screen, .tracking(task: sampleTask, startedAt: explicitStart))
    }

    func test_retask_changesTrackingTaskButKeepsOriginalStartedAt() {
        let explicitStart = Date(timeIntervalSince1970: 1_000_000_000)
        let state = AppState(clock: { Date(timeIntervalSince1970: 9_999_999_999) })
        state.logIn()
        state.startTracking(sampleTask, startedAt: explicitStart)

        let newTask = TrackedTaskRef(
            clientId: "client-1", clientName: "Acme",
            projectId: "proj-1", projectName: "Website Redesign",
            taskId: "task-2", taskName: "Design"
        )
        state.retask(newTask)

        // Same instant as before `retask` — "Switch task" edits a still-running timer in place,
        // so the elapsed-time baseline must not jump to now.
        XCTAssertEqual(state.screen, .tracking(task: newTask, startedAt: explicitStart))
        XCTAssertEqual(state.mostRecent, newTask)
    }

    func test_retask_whileNotTracking_isANoOp() {
        let state = AppState()
        state.logIn()

        state.retask(sampleTask)

        XCTAssertEqual(state.screen, .idleNoHistory)
    }

    func test_retask_firesOnChange() {
        let state = AppState()
        state.logIn()
        state.startTracking(sampleTask)
        var changed = false
        state.onChange = { changed = true }

        state.retask(TrackedTaskRef(
            clientId: "client-1", clientName: "Acme",
            projectId: "proj-1", projectName: "Website Redesign",
            taskId: "task-2", taskName: "Design"
        ))

        XCTAssertTrue(changed)
    }
}
