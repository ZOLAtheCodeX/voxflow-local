import Foundation
import Security
import os

enum KeychainService {
    private static let serviceName = "local.voxflow.app"
    private static let log = Logger(subsystem: "local.voxflow.app", category: "KeychainService")

    /// Session 29 review: save() used to discard both SecItem statuses — a
    /// keychain ACL failure (real mode after a re-sign) DESTROYED the old
    /// secret, dropped the new one, and the caller marked the key
    /// "configured" anyway. Callers must branch on the result.
    @discardableResult
    static func save(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        let deleteStatus = SecItemDelete(query as CFDictionary)

        var addStatus: OSStatus?
        if !value.isEmpty {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        }

        let succeeded = Self.saveSucceeded(deleteStatus: deleteStatus, addStatus: addStatus)
        if !succeeded {
            log.error("Keychain save failed for \(account): delete=\(deleteStatus), add=\(addStatus.map(String.init(describing:)) ?? "skipped")")
        }
        return succeeded
    }

    /// Pure outcome classifier (testable without touching the real keychain).
    /// Deleting a non-existent item is fine (errSecItemNotFound); an add, when
    /// performed, must succeed. A clear (empty value, no add) succeeds when
    /// the delete either worked or had nothing to remove.
    nonisolated static func saveSucceeded(deleteStatus: OSStatus, addStatus: OSStatus?) -> Bool {
        let deleteOK = deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        guard let addStatus else { return deleteOK }
        return addStatus == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
