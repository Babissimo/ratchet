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
