// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `@MainActor`-isolated because every consumer is UI code (`StatusItemController`,
/// `MenuBuilder`) that reads these properties on the main thread. Isolating the protocol
/// keeps conforming stores' mutations serialized on the main actor — only the actual
/// network awaits inside implementations suspend — instead of letting `async` methods
/// hop onto a background executor and mutate shared state while the menu reads it.
@MainActor
public protocol DataStore: AnyObject {
    var clients: [RatchetClient] { get }
    var accountEmail: String { get }
    var timeslips: [RatchetTimeslip] { get }
    var lastRefreshedAt: Date? { get }
    /// True when a local write has landed that no completed `refresh()` has yet reconciled.
    ///
    /// `lastRefreshedAt` alone can't answer "is what I'm showing current?", because it only
    /// moves on a refresh: a start, stop, switch or logged entry changes server state while
    /// leaving it untouched. `StatusItemController`'s 120-second staleness gate consults this
    /// alongside the timestamp, so a write always forces the next refresh through.
    var hasLocalWritesSinceRefresh: Bool { get }
    /// The timeslip whose timer is currently running, if any; nil when nothing is. FreeAgent
    /// doesn't live-update a running timeslip's `hours` — it only reflects hours as of the last
    /// pause — so `MenuBuilder.buildRecentTimeEntriesSubmenu` excludes this entry rather than
    /// showing a duration that's stale from the moment the timer was last resumed.
    var currentRunningTimeslip: RatchetTimeslip? { get }
    /// The signed-in account's own FreeAgent web app URL, for "Open FreeAgent" — nil until
    /// known (e.g. before the first successful `refresh()`).
    var webAppURL: URL? { get }

    /// The authoritative "what is running right now", read from the server. `currentRunningTimeslip`
    /// above is a cache and can name a timeslip that was stopped from the FreeAgent web app,
    /// another device, or simply yesterday — anything about to *write* to the running timeslip
    /// must go through this instead.
    func runningTimeslip() async throws -> RatchetTimeslip?

    /// Throws `DataStoreError.unconfirmed(.task)` when it can't tell whether FreeAgent made the
    /// task. Asked again for the same name in the same project, it returns the task that attempt
    /// made, if it finds one, rather than making a second.
    func addTask(
        name: String,
        projectId: String,
        clientId: String,
        isBillable: Bool,
        status: TaskStatus,
        billingRate: Double?,
        billingPeriod: BillingPeriod?
    ) async throws -> RatchetTask

    /// Names are passed through structurally rather than pre-flattened into one display string:
    /// FreeAgent stores an organisation and a person differently, and collapsing "Jane" + "Doe"
    /// into an `organisation_name` made every individual client show up as a company on invoices
    /// with its name fields empty. Validation ("an organisation name, OR both first and last")
    /// still happens at the form; the store just needs the pieces.
    ///
    /// Throws `DataStoreError.unconfirmed(.client)` as `addTask` does for a task, and a call with
    /// the same organisation, or for a person the same first and last name, settles it the same
    /// way.
    func addClient(
        organisationName: String?,
        firstName: String?,
        lastName: String?,
        email: String?,
        phoneNumber: String?,
        address1: String?,
        town: String?,
        postcode: String?,
        country: String?
    ) async throws -> RatchetClient

    /// Throws `DataStoreError.unconfirmed(.project)` as `addTask` does for a task, and a call with
    /// the same name for the same client settles it the same way.
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

    /// Throws `DataStoreError.unconfirmed(.timeslip)` when it can't tell whether FreeAgent logged
    /// the entry, and `DataStoreError.alreadyLogged` when a later identical call finds that it
    /// did; the entry is then in `timeslips`.
    func logTime(
        taskId: String,
        projectId: String,
        clientId: String,
        date: Date,
        hours: Double,
        comment: String?
    ) async throws -> RatchetTimeslip

    /// Edits an already-logged entry in place — the counterpart to `logTime`'s "create". `id`
    /// identifies the timeslip being changed; the rest are its full replacement values, a nil
    /// `comment` meaning it has none, including which client/project/task it's now booked
    /// against, so "Recent time entries" can reassign a mis-logged entry rather than only
    /// tweaking its hours/comment.
    func updateTimeslip(
        id: String,
        taskId: String,
        projectId: String,
        clientId: String,
        date: Date,
        hours: Double,
        comment: String?
    ) async throws -> RatchetTimeslip

    /// Replaces the cached account with what FreeAgent reports, and returns only once it has:
    /// callers reconcile against the result without checking. A fetch that one of this store's own
    /// writes overlapped may predate it, so the store waits for the write and fetches again
    /// rather than return early or commit it.
    func refresh() async throws

    /// Starts (or resumes) today's timer for the given task. Returns the
    /// timeslip the timer is running on; its effective start instant is
    /// the UI's elapsed-time baseline.
    func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip

    /// Stops whichever timeslip currently has a running timer. Returns
    /// the updated timeslip, or nil if nothing was running.
    func stopTimer() async throws -> RatchetTimeslip?
}
