// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RatchetCore

extension FreeAgentContactDTO {
    /// FreeAgent's client display name: organisation name if present,
    /// otherwise "First Last".
    var displayName: String {
        if let organisationName, !organisationName.isEmpty { return organisationName }
        return [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }

    func toRatchetClient(projects: [RatchetProject]) -> RatchetClient {
        RatchetClient(
            id: url,
            name: displayName,
            projects: projects,
            email: email,
            phoneNumber: phoneNumber,
            address1: address1,
            town: town,
            postcode: postcode,
            country: country
        )
    }
}

extension FreeAgentProjectDTO {
    func toRatchetProject(tasks: [RatchetTask]) -> RatchetProject {
        RatchetProject(
            id: url,
            name: name,
            tasks: tasks,
            status: ProjectStatus(rawValue: status) ?? .active,
            currency: currency,
            budget: budget.flatMap(Double.init) ?? 0,
            budgetUnits: budgetUnits.flatMap(BudgetUnits.init(rawValue:)) ?? .hours,
            hoursPerDay: hoursPerDay.flatMap(Double.init) ?? 8,
            normalBillingRate: normalBillingRate.flatMap(Double.init) ?? 0,
            billingPeriod: billingPeriod.flatMap(BillingPeriod.init(rawValue:)) ?? .hour,
            usesProjectInvoiceSequence: usesProjectInvoiceSequence ?? false,
            contractPoReference: contractPoReference,
            startsOn: startsOn.flatMap { CalendarDay.day(from: $0) },
            endsOn: endsOn.flatMap { CalendarDay.day(from: $0) }
        )
    }
}

extension FreeAgentTaskDTO {
    func toRatchetTask() -> RatchetTask {
        RatchetTask(
            id: url,
            name: name,
            isBillable: isBillable,
            status: TaskStatus(rawValue: status) ?? .active,
            billingRate: billingRate.flatMap(Double.init),
            billingPeriod: billingPeriod.flatMap(BillingPeriod.init(rawValue:))
        )
    }
}

extension FreeAgentTimeslipDTO {
    func toRatchetTimeslip() -> RatchetTimeslip {
        RatchetTimeslip(
            id: url,
            clientId: "", // filled in by FreeAgentDataStore, which knows project->client
            projectId: project,
            taskId: task,
            // `dated_on` is a plain calendar day, parsed as local midnight so it displays as
            // the day the user picked rather than slipping back one west of UTC. The fallback
            // is `.distantPast` rather than `Date()`: an unparseable day is a broken record,
            // and dating it "today" would quietly file it under the wrong day and re-sort the
            // Recent list around it.
            day: CalendarDay.day(from: datedOn) ?? .distantPast,
            // Only a *running* timer's start is a live baseline. FreeAgent can return a timer
            // object with running:false, and treating that start_from as live made a paused
            // entry look like it had been counting since that instant.
            timerStartedAt: (timer?.running == true) ? timer?.startFrom : nil,
            hours: Double(hours) ?? 0,
            comment: comment,
            isInvoiced: billedOnInvoice != nil,
            updatedAt: updatedAt
        )
    }
}
