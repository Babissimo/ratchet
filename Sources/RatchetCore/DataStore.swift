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
    ) -> RatchetTask?
    func addClient(
        name: String,
        email: String?,
        phoneNumber: String?,
        address1: String?,
        town: String?,
        postcode: String?,
        country: String?
    ) -> RatchetClient?
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
    ) -> RatchetProject?
    func logTime(
        taskId: String,
        projectId: String,
        clientId: String,
        date: Date,
        hours: Double,
        comment: String?
    ) -> RatchetTimeslip?
    func refresh()
}
