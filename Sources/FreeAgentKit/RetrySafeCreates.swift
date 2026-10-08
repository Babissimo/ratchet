// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RatchetCore

/// A resource as a FreeAgent create returns it and a list repeats it.
protocol CreatedResource {
    var url: String { get }
    var createdAt: Date? { get }
}

extension FreeAgentTimeslipDTO: CreatedResource {}
extension FreeAgentContactDTO: CreatedResource {}
extension FreeAgentProjectDTO: CreatedResource {}
extension FreeAgentTaskDTO: CreatedResource {}

/// What a create sends that identifies the resource it makes, so a create whose outcome is
/// unknown can be matched both to that resource and to a retry.
protocol CreateIdentity: Hashable {
    associatedtype Resource: CreatedResource
    /// What the create makes, for the error that says it may not have.
    static var made: DataStoreError.Resource { get }
    /// Whether `resource` is one a create with this identity would have made.
    func identifies(_ resource: Resource) -> Bool
}

/// Allows for the Mac's clock running ahead of FreeAgent's, and for `created_at` being whole
/// seconds, when a request's send time is compared with the `created_at` of its result.
private let clockSkewAllowance: TimeInterval = 5 * 60

/// The creates of one kind of resource, made safe to retry. FreeAgent has no idempotency key, so
/// a create whose outcome is unknown is remembered and settled by looking for the resource it
/// would have made: straight away, and again before a create with the same identity is posted.
@MainActor
final class RetrySafeCreates<Identity: CreateIdentity> {
    typealias Resource = Identity.Resource
    /// `isEarlierAttempt` is true when the look before posting found the resource, so nothing
    /// was posted this time.
    typealias Outcome = (resource: Resource, isEarlierAttempt: Bool)

    /// A create that may have reached FreeAgent although no response reached Ratchet.
    private struct Uncertain {
        let sentAt: Date
        /// Resources already cached when it was sent, none of which can be its result.
        let knownIds: Set<String>
    }

    private let apiClient: FreeAgentAPIClient
    private let clock: () -> Date

    private var uncertain: [Identity: Uncertain] = [:]

    /// Every resource these creates have made or adopted, none of which can be the result of
    /// another create, including one still in flight. `Uncertain.knownIds` can't cover these when
    /// the cache drops them, as the timeslip cache drops a back-dated entry at the next refresh.
    private var ownIds: Set<String> = []

    /// The last create queued for each identity. Creates with the same identity run one at a
    /// time, so each is settled before the next is posted: run together, one can adopt the
    /// other's resource before that create's response arrives, or post while the other's outcome
    /// is still open.
    private var queued: [Identity: Task<Outcome, Error>] = [:]

    init(apiClient: FreeAgentAPIClient, clock: @escaping () -> Date) {
        self.apiClient = apiClient
        self.clock = clock
    }

    /// Posts a create, unless an earlier one with the same identity turns out to have made it.
    /// `cachedIds` reads the cache as the create is sent; `candidates` lists the resources that
    /// may be its result, which include every one created since the date it is given.
    func create(
        _ identity: Identity,
        cachedIds: @escaping () -> Set<String>,
        candidates: @escaping (_ createdSince: Date) async throws -> [Resource],
        post: @escaping () async throws -> Resource
    ) async throws -> Outcome {
        let previous = queued[identity]
        let create = Task { [self] in
            _ = try? await previous?.value
            return try await perform(identity, cachedIds: cachedIds, candidates: candidates, post: post)
        }
        queued[identity] = create
        defer { if queued[identity] == create { queued[identity] = nil } }
        return try await create.value
    }

    private func perform(
        _ identity: Identity,
        cachedIds: () -> Set<String>,
        candidates: (Date) async throws -> [Resource],
        post: () async throws -> Resource
    ) async throws -> Outcome {
        if let earlier = uncertain[identity], let found = try await findCreated(identity, by: earlier, in: candidates) {
            settle(identity, as: found)
            return (found, true)
        }
        // Outside the POST, so an expired token failing to refresh reads as nothing sent.
        try await apiClient.prepareTokens()
        let sentAt = clock()
        let cachedAtSend = cachedIds()
        do {
            let created = try await post()
            settle(identity, as: created)
            return (created, false)
        } catch where Self.mayHaveBeenApplied(error) {
            // Kept, and reported as unconfirmed, even when the look below finds nothing: a
            // request that timed out can still commit after the look has run. An earlier record
            // for the same identity is kept in preference, since its window covers both attempts.
            let record = uncertain[identity] ?? Uncertain(sentAt: sentAt, knownIds: cachedAtSend)
            uncertain[identity] = record
            // Not the original error: a plain network error reads as "not created" and invites a
            // blind retry.
            guard let found = try await findCreated(identity, by: record, in: candidates) else {
                throw DataStoreError.unconfirmed(Identity.made)
            }
            settle(identity, as: found)
            return (found, false)
        }
    }

    private func settle(_ identity: Identity, as result: Resource) {
        uncertain[identity] = nil
        ownIds.insert(result.url)
    }

    /// Whether a create that threw may still have been applied. A 4xx is FreeAgent refusing it;
    /// no response at all, a 5xx (a gateway gives up on requests the app may yet complete), or a
    /// success whose body didn't decode leaves the outcome open.
    private static func mayHaveBeenApplied(_ error: Error) -> Bool {
        switch error as? FreeAgentError {
        case .network(let underlying)?:
            // Name resolution and connecting both fail before any of the request is sent.
            // `.notConnectedToInternet` describes the interface rather than this request, so it
            // can't vouch that nothing went out.
            let unsent: Set<URLError.Code> = [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost]
            return (underlying as? URLError).map { !unsent.contains($0.code) } ?? true
        case .decoding?: return true
        case .apiError(let status, _)?: return status >= 500
        default: return false
        }
    }

    /// The resource `attempt` created, if FreeAgent applied it.
    private func findCreated(
        _ identity: Identity, by attempt: Uncertain, in candidates: (Date) async throws -> [Resource]
    ) async throws -> Resource? {
        let earliest = attempt.sentAt.addingTimeInterval(-clockSkewAllowance)
        let listed: [Resource]
        do {
            listed = try await candidates(earliest)
        } catch where !error.indicatesSessionExpired {
            throw DataStoreError.unconfirmed(Identity.made)
        }
        let matches = listed.compactMap { resource -> (resource: Resource, createdAt: Date)? in
            guard let createdAt = resource.createdAt, createdAt >= earliest, !attempt.knownIds.contains(resource.url),
                  !ownIds.contains(resource.url), identity.identifies(resource) else { return nil }
            return (resource, createdAt)
        }
        // The earliest is the likeliest to be this request's own.
        return matches.min { $0.createdAt < $1.createdAt }?.resource
    }
}
