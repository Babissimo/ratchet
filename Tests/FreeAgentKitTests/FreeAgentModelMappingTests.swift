import XCTest
@testable import FreeAgentKit
import RatchetCore

final class FreeAgentModelMappingTests: XCTestCase {
    func test_contactDTO_prefersOrganisationNameOverPersonName() {
        let dto = FreeAgentContactDTO(
            url: "https://api.sandbox.freeagent.com/v2/contacts/1",
            organisationName: "Acme Ltd",
            firstName: "Jane", lastName: "Doe",
            email: nil, phoneNumber: nil, address1: nil, town: nil, postcode: nil, country: nil
        )
        let client = dto.toRatchetClient(projects: [])
        XCTAssertEqual(client.name, "Acme Ltd")
        XCTAssertEqual(client.id, "https://api.sandbox.freeagent.com/v2/contacts/1")
    }

    func test_contactDTO_fallsBackToFirstLastNameWhenNoOrganisation() {
        let dto = FreeAgentContactDTO(
            url: "https://api.sandbox.freeagent.com/v2/contacts/2",
            organisationName: nil,
            firstName: "Jane", lastName: "Doe",
            email: nil, phoneNumber: nil, address1: nil, town: nil, postcode: nil, country: nil
        )
        XCTAssertEqual(dto.toRatchetClient(projects: []).name, "Jane Doe")
    }

    func test_projectDTO_mapsStatusAndNumericFieldsWithDefaults() {
        let dto = FreeAgentProjectDTO(
            url: "https://api.sandbox.freeagent.com/v2/projects/1",
            contact: "https://api.sandbox.freeagent.com/v2/contacts/1",
            name: "Website Redesign",
            status: "Active",
            currency: "GBP",
            budget: "1000.0", budgetUnits: "Hours",
            hoursPerDay: "8.0", normalBillingRate: "50.0", billingPeriod: "hour",
            usesProjectInvoiceSequence: false, contractPoReference: nil,
            startsOn: "2026-01-01", endsOn: nil
        )
        let project = dto.toRatchetProject(tasks: [])
        XCTAssertEqual(project.status, .active)
        XCTAssertEqual(project.budget, 1000.0)
        XCTAssertEqual(project.hoursPerDay, 8.0)
        XCTAssertNotNil(project.startsOn)
        XCTAssertNil(project.endsOn)
    }

    func test_projectDTO_decodesBudgetAsRawJSONNumber() throws {
        // FreeAgent isn't consistent: observed against the sandbox API, `budget` comes back as a
        // bare JSON number (e.g. `"budget":0`) on project creation, while `normal_billing_rate`
        // and `hours_per_day` come back as strings in that same response.
        let json = Data(#"""
        {
            "url": "https://api.sandbox.freeagent.com/v2/projects/1",
            "contact": "https://api.sandbox.freeagent.com/v2/contacts/1",
            "name": "Website Redesign",
            "status": "Active",
            "currency": "GBP",
            "budget": 0,
            "budget_units": "Hours",
            "hours_per_day": "8.0",
            "normal_billing_rate": "50.0",
            "billing_period": "hour",
            "uses_project_invoice_sequence": false
        }
        """#.utf8)

        let dto = try JSONDecoder().decode(FreeAgentProjectDTO.self, from: json)

        XCTAssertEqual(dto.budget, "0")
    }

    func test_projectDTO_stillDecodesBudgetAsString() throws {
        let json = Data(#"""
        {
            "url": "https://api.sandbox.freeagent.com/v2/projects/1",
            "contact": "https://api.sandbox.freeagent.com/v2/contacts/1",
            "name": "Website Redesign",
            "status": "Active",
            "currency": "GBP",
            "budget": "1500.5",
            "budget_units": "Hours",
            "hours_per_day": "8.0",
            "normal_billing_rate": "50.0",
            "billing_period": "hour",
            "uses_project_invoice_sequence": false
        }
        """#.utf8)

        let dto = try JSONDecoder().decode(FreeAgentProjectDTO.self, from: json)

        XCTAssertEqual(dto.budget, "1500.5")
    }

    func test_taskDTO_mapsBillingFields() {
        let dto = FreeAgentTaskDTO(
            url: "https://api.sandbox.freeagent.com/v2/tasks/1",
            project: "https://api.sandbox.freeagent.com/v2/projects/1",
            name: "Development",
            isBillable: true,
            status: "Active",
            billingRate: "75.0",
            billingPeriod: "hour"
        )
        let task = dto.toRatchetTask()
        XCTAssertEqual(task.billingRate, 75.0)
        XCTAssertEqual(task.billingPeriod, .hour)
    }

    func test_timeslipDTO_withRunningTimer_usesTimerStartFromAsDate() {
        let startFrom = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = FreeAgentTimeslipDTO(
            url: "https://api.sandbox.freeagent.com/v2/timeslips/1",
            project: "https://api.sandbox.freeagent.com/v2/projects/1",
            task: "https://api.sandbox.freeagent.com/v2/tasks/1",
            user: "https://api.sandbox.freeagent.com/v2/users/1",
            datedOn: "2023-11-14",
            hours: "0.0",
            comment: nil,
            timer: FreeAgentTimerDTO(running: true, startFrom: startFrom)
        )
        XCTAssertEqual(dto.toRatchetTimeslip().date, startFrom)
    }

    func test_timeslipDTO_withoutTimer_usesDatedOn() {
        let dto = FreeAgentTimeslipDTO(
            url: "https://api.sandbox.freeagent.com/v2/timeslips/2",
            project: "https://api.sandbox.freeagent.com/v2/projects/1",
            task: "https://api.sandbox.freeagent.com/v2/tasks/1",
            user: "https://api.sandbox.freeagent.com/v2/users/1",
            datedOn: "2023-11-14",
            hours: "1.5",
            comment: "worked on the thing",
            timer: nil
        )
        let timeslip = dto.toRatchetTimeslip()
        XCTAssertEqual(timeslip.hours, 1.5)
        XCTAssertEqual(timeslip.comment, "worked on the thing")
    }

    func test_timeslipDTO_withoutBilledOnInvoice_isNotInvoiced() {
        let dto = FreeAgentTimeslipDTO(
            url: "https://api.sandbox.freeagent.com/v2/timeslips/3",
            project: "https://api.sandbox.freeagent.com/v2/projects/1",
            task: "https://api.sandbox.freeagent.com/v2/tasks/1",
            user: "https://api.sandbox.freeagent.com/v2/users/1",
            datedOn: "2023-11-14",
            hours: "1.0",
            comment: nil,
            timer: nil
        )
        XCTAssertFalse(dto.toRatchetTimeslip().isInvoiced)
    }

    func test_timeslipDTO_withBilledOnInvoice_isInvoiced() {
        let dto = FreeAgentTimeslipDTO(
            url: "https://api.sandbox.freeagent.com/v2/timeslips/4",
            project: "https://api.sandbox.freeagent.com/v2/projects/1",
            task: "https://api.sandbox.freeagent.com/v2/tasks/1",
            user: "https://api.sandbox.freeagent.com/v2/users/1",
            datedOn: "2023-11-14",
            hours: "1.0",
            comment: nil,
            timer: nil,
            billedOnInvoice: "https://api.sandbox.freeagent.com/v2/invoices/1"
        )
        XCTAssertTrue(dto.toRatchetTimeslip().isInvoiced)
    }
}
