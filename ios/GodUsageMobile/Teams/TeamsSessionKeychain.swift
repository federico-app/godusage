import Foundation
import Security

/// The paired session, kept in the Keychain (this device only, readable after the first unlock).
enum TeamsSessionKeychain {
    private static let service = "com.montinovo.godusage.mobile.teams"
    private static let account = "session"

    struct Failure: Error, LocalizedError {
        var status: OSStatus
        var errorDescription: String? { "The Keychain refused the GodUsage sign-in (error \(status))." }
    }

    static func load() throws -> TeamsSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return try JSONDecoder().decode(TeamsSession.self, from: data)
    }

    static func save(_ session: TeamsSession?) throws {
        let deleted = SecItemDelete(baseQuery as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Failure(status: deleted) }
        guard let session else { return }
        var item = baseQuery
        item[kSecValueData as String] = try JSONEncoder().encode(session)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
