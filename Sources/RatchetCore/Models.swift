// SPDX-License-Identifier: GPL-3.0-or-later
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
    /// `var` purely so `withTasks(_:)` can copy-and-replace without re-listing every other
    /// field. Stores expose their `clients` as `private(set)`, so this isn't a mutation route
    /// for callers.
    public var tasks: [RatchetTask]
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

    /// A copy with a different task list.
    ///
    /// Deliberately `var copy = self` rather than a call to `init` listing all fourteen fields:
    /// the hand-rolled version compiles fine when a new property is added (the initializer
    /// defaults it), so appending a task would silently reset whatever the new field held.
    public func withTasks(_ tasks: [RatchetTask]) -> RatchetProject {
        var copy = self
        copy.tasks = tasks
        return copy
    }
}

public struct RatchetClient: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    /// `var` for the same reason as `RatchetProject.tasks` — see `withProjects(_:)`.
    public var projects: [RatchetProject]
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

    /// A copy with a different project list. See `RatchetProject.withTasks(_:)` for why this
    /// copies rather than re-invoking `init`.
    public func withProjects(_ projects: [RatchetProject]) -> RatchetClient {
        var copy = self
        copy.projects = projects
        return copy
    }

    /// A copy with one project replaced in place, addressed by index.
    public func replacingProject(at index: Int, with project: RatchetProject) -> RatchetClient {
        var projects = self.projects
        projects[index] = project
        return withProjects(projects)
    }
}

public struct RatchetTimeslip: Identifiable, Equatable, Codable {
    public let id: String
    /// `var` purely so `withClientId(_:)` can copy-and-replace without re-listing every other
    /// field — see `RatchetProject.withTasks(_:)`. `FreeAgentDataStore` exposes timeslips only
    /// through `private(set)` arrays, so this isn't a mutation route for callers.
    public var clientId: String
    public let projectId: String
    public let taskId: String
    /// The calendar day this work is booked against — always local midnight of FreeAgent's
    /// `dated_on`, never an instant. Kept separate from `timerStartedAt` because one field
    /// used to mean both: it held `timer.start_from` when a timer object was present and local
    /// midnight otherwise, so the same property was an instant or a day depending on which
    /// endpoint had last filled it in, and the elapsed-time display read midnight as a start.
    public let day: Date
    /// When the currently-running timer on this timeslip started, or nil if no timer is
    /// running on it. The only correct baseline for elapsed time. `var` for the same reason as
    /// `clientId` above — see `withTimerStartedAt(_:)`.
    public var timerStartedAt: Date?
    public let hours: Double
    public let comment: String?
    /// Whether FreeAgent has already billed this entry on an invoice. An invoiced entry is
    /// closed on FreeAgent's side — "Recent time entries" shows it but can't offer to edit it.
    public let isInvoiced: Bool

    public init(
        id: String, clientId: String, projectId: String, taskId: String, day: Date,
        timerStartedAt: Date? = nil, hours: Double, comment: String? = nil, isInvoiced: Bool = false
    ) {
        self.id = id
        self.clientId = clientId
        self.projectId = projectId
        self.taskId = taskId
        self.day = day
        self.timerStartedAt = timerStartedAt
        self.hours = hours
        self.comment = comment
        self.isInvoiced = isInvoiced
    }

    /// A copy with a different client id. See `RatchetProject.withTasks(_:)` for why this copies
    /// rather than re-invoking `init` — `RatchetTimeslip.init` defaults `timerStartedAt`,
    /// `comment` and `isInvoiced`, so a hand-rolled copy that lists every field silently drops
    /// any future defaulted field the copy forgot to carry forward.
    public func withClientId(_ clientId: String) -> RatchetTimeslip {
        var copy = self
        copy.clientId = clientId
        return copy
    }

    /// A copy with a different timer-start instant. See `withClientId(_:)` above.
    public func withTimerStartedAt(_ timerStartedAt: Date?) -> RatchetTimeslip {
        var copy = self
        copy.timerStartedAt = timerStartedAt
        return copy
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
