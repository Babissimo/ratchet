import Foundation

public enum TaskStatus: String, CaseIterable, Codable {
    case active = "Active"
    case completed = "Completed"
    case hidden = "Hidden"
}

public struct RatchetTask: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let isBillable: Bool
    public let status: TaskStatus
    public let billingRate: Double?
    public let billingPeriod: BillingPeriod?

    public init(
        id: String,
        name: String,
        isBillable: Bool = true,
        status: TaskStatus = .active,
        billingRate: Double? = nil,
        billingPeriod: BillingPeriod? = nil
    ) {
        self.id = id
        self.name = name
        self.isBillable = isBillable
        self.status = status
        self.billingRate = billingRate
        self.billingPeriod = billingPeriod
    }
}

public enum ProjectStatus: String, CaseIterable, Codable {
    case active = "Active"
    case completed = "Completed"
    case cancelled = "Cancelled"
    case hidden = "Hidden"
}

public enum BudgetUnits: String, CaseIterable, Codable {
    case hours = "Hours"
    case days = "Days"
    case monetary = "Monetary (ex-VAT)"
}

public enum BillingPeriod: String, CaseIterable, Codable {
    case hour = "hour"
    case day = "day"
}

public struct RatchetProject: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let tasks: [RatchetTask]
    public let status: ProjectStatus
    public let currency: String
    public let budget: Double
    public let budgetUnits: BudgetUnits
    public let hoursPerDay: Double
    public let normalBillingRate: Double
    public let billingPeriod: BillingPeriod
    public let usesProjectInvoiceSequence: Bool
    public let contractPoReference: String?
    public let startsOn: Date?
    public let endsOn: Date?

    public init(
        id: String,
        name: String,
        tasks: [RatchetTask],
        status: ProjectStatus = .active,
        currency: String = "GBP",
        budget: Double = 0,
        budgetUnits: BudgetUnits = .hours,
        hoursPerDay: Double = 8,
        normalBillingRate: Double = 0,
        billingPeriod: BillingPeriod = .hour,
        usesProjectInvoiceSequence: Bool = false,
        contractPoReference: String? = nil,
        startsOn: Date? = nil,
        endsOn: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.tasks = tasks
        self.status = status
        self.currency = currency
        self.budget = budget
        self.budgetUnits = budgetUnits
        self.hoursPerDay = hoursPerDay
        self.normalBillingRate = normalBillingRate
        self.billingPeriod = billingPeriod
        self.usesProjectInvoiceSequence = usesProjectInvoiceSequence
        self.contractPoReference = contractPoReference
        self.startsOn = startsOn
        self.endsOn = endsOn
    }
}

public struct RatchetClient: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let projects: [RatchetProject]
    public let email: String?
    public let phoneNumber: String?
    public let address1: String?
    public let town: String?
    public let postcode: String?
    public let country: String?

    public init(
        id: String,
        name: String,
        projects: [RatchetProject],
        email: String? = nil,
        phoneNumber: String? = nil,
        address1: String? = nil,
        town: String? = nil,
        postcode: String? = nil,
        country: String? = nil
    ) {
        self.id = id
        self.name = name
        self.projects = projects
        self.email = email
        self.phoneNumber = phoneNumber
        self.address1 = address1
        self.town = town
        self.postcode = postcode
        self.country = country
    }
}

public struct RatchetTimeslip: Identifiable, Equatable, Codable {
    public let id: String
    public let clientId: String
    public let projectId: String
    public let taskId: String
    public let date: Date
    public let hours: Double
    public let comment: String?

    public init(id: String, clientId: String, projectId: String, taskId: String, date: Date, hours: Double, comment: String? = nil) {
        self.id = id
        self.clientId = clientId
        self.projectId = projectId
        self.taskId = taskId
        self.date = date
        self.hours = hours
        self.comment = comment
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
