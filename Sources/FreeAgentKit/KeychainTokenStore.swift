// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Why this exists instead of an `Optional`: `load()` returning nil conflated "there are no
/// stored credentials" with "the Keychain could not be read right now" (locked, an ACL prompt
/// declined, `errSecNotAvailable` early in boot). The caller mapped both to
/// `FreeAgentError.unauthorized`, which the app treats as a dead session — so a transient read
/// failure deleted a perfectly valid refresh token and forced a re-login.
public enum TokenLoadResult {
    case found(FreeAgentTokens)
    /// Definitively no usable credentials: nothing stored, or stored bytes that no longer
    /// decode. Logging out is the correct response.
    case missing
    /// The Keychain itself failed. Says nothing about the session — never log out on this.
    case unavailable(OSStatus)
}

public final class KeychainTokenStore {
    let service: String
    private let account = "default"

    public init(service: String) {
        self.service = service
    }

    /// Sandbox and production builds share a bundle id, so each environment needs its own item or
    /// signing in to one would overwrite the other's session. Production must keep the unsuffixed
    /// name: existing sign-ins are stored under it.
    public convenience init(environment: FreeAgentEnvironment) {
        switch environment {
        case .production: self.init(service: "com.ratchet.freeagent")
        case .sandbox: self.init(service: "com.ratchet.freeagent.sandbox")
        }
    }

    public func loadResult() -> TokenLoadResult {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let tokens = try? JSONDecoder().decode(FreeAgentTokens.self, from: data) else {
                // The item is there but unusable, which a re-login does fix — unlike a
                // Keychain that simply wouldn't answer.
                return .missing
            }
            return .found(tokens)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    /// Convenience for call sites that genuinely only need "do we appear to have credentials"
    /// and take no destructive action either way (e.g. `AppDelegate`'s launch-time seed).
    /// Anything that might log the user out must use `loadResult()` instead.
    public func load() -> FreeAgentTokens? {
        if case .found(let tokens) = loadResult() { return tokens }
        return nil
    }

    /// Persists `tokens`, returning false if the Keychain refused the write.
    ///
    /// Update-then-add rather than the delete-then-add this used to do. FreeAgent rotates the
    /// refresh token on every use, so this runs on every token refresh — and the old sequence
    /// deleted the existing item *first*, meaning any failure of the subsequent add (Keychain
    /// locked, ACL prompt denied, the app re-signed with a fresh ad-hoc signature between
    /// builds) destroyed the only good credentials on disk. The rotated token then existed
    /// solely in memory: the session worked until quit, and the next launch found nothing and
    /// silently logged the user out. Updating in place leaves the previous item intact when the
    /// write fails, and the `OSStatus` is now returned rather than dropped.
    @discardableResult
    public func save(_ tokens: FreeAgentTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = itemQuery
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public func clear() {
        SecItemDelete(itemQuery as CFDictionary)
    }

    /// Identifies the single generic-password item this store owns.
    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
