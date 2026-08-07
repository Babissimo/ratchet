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
