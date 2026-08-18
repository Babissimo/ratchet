// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

public final class KeychainTokenStore {
    private let service: String
    private let account = "default"

    public init(service: String = "com.ratchet.freeagent") {
        self.service = service
    }

    public func load() -> FreeAgentTokens? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FreeAgentTokens.self, from: data)
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
