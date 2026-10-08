// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// FreeAgent isn't always consistent about whether a numeric-looking field comes back as a JSON
/// string or a JSON number for the same logical value across endpoints/responses (observed:
/// `budget` comes back as a bare number on project creation, while `normal_billing_rate` and
/// `hours_per_day` come back as strings in that same response). Decodes either shape into a
/// `String`, matching what the rest of this file already expects for these fields.
@propertyWrapper
public struct LenientNumericString: Codable {
    public let wrappedValue: String?

    public init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            wrappedValue = string
        } else if let double = try? container.decode(Double.self) {
            wrappedValue = String(double)
        } else if container.decodeNil() {
            wrappedValue = nil
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

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
    /// Server time (UTC). Optional for the same reason as `FreeAgentTimeslipDTO.updatedAt`.
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case url
        case organisationName = "organisation_name"
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case phoneNumber = "phone_number"
        case address1, town, postcode, country
        case createdAt = "created_at"
    }
}

public struct FreeAgentProjectDTO: Codable {
    public let url: String
    public let contact: String
    public let name: String
    public let status: String
    public let currency: String
    @LenientNumericString public var budget: String?
    public let budgetUnits: String?
    public let hoursPerDay: String?
    public let normalBillingRate: String?
    public let billingPeriod: String?
    public let usesProjectInvoiceSequence: Bool?
    public let contractPoReference: String?
    public let startsOn: String?
    public let endsOn: String?
    /// Server time (UTC). Optional for the same reason as `FreeAgentTimeslipDTO.updatedAt`.
    public let createdAt: Date?

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
        case createdAt = "created_at"
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
    /// Server time (UTC). Optional for the same reason as `FreeAgentTimeslipDTO.updatedAt`.
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case url, project, name
        case isBillable = "is_billable"
        case status
        case billingRate = "billing_rate"
        case billingPeriod = "billing_period"
        case createdAt = "created_at"
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
    /// URI of the invoice this timeslip has been billed on, if any — FreeAgent's only signal
    /// that a timeslip is invoiced (there's no separate status field).
    public let billedOnInvoice: String?
    /// Optional because not every timeslip-bearing response carries it — the `POST /timer`
    /// and timeslip PUT replies in particular — and a missing timestamp must not fail the
    /// whole decode of an otherwise usable record.
    public let updatedAt: Date?
    /// Server time (UTC). Optional for the same reason as `updatedAt`.
    public let createdAt: Date?

    public init(
        url: String, project: String, task: String, user: String, datedOn: String, hours: String,
        comment: String?, timer: FreeAgentTimerDTO?, billedOnInvoice: String? = nil,
        updatedAt: Date? = nil, createdAt: Date? = nil
    ) {
        self.url = url
        self.project = project
        self.task = task
        self.user = user
        self.datedOn = datedOn
        self.hours = hours
        self.comment = comment
        self.timer = timer
        self.billedOnInvoice = billedOnInvoice
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case url, project, task, user
        case datedOn = "dated_on"
        case hours, comment, timer
        case billedOnInvoice = "billed_on_invoice"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
    }
}

public struct FreeAgentUserDTO: Codable {
    public let url: String
    public let email: String
}

public struct FreeAgentCompanyDTO: Codable {
    public let subdomain: String
}
