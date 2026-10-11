import Foundation
import Security

public enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            "Keychain request failed with status \(status)."
        }
    }
}

public protocol SecretStringStoring {
    func string(for account: String) throws -> String?
    func setString(_ value: String, for account: String) throws
}

public struct KeychainStore: Sendable, SecretStringStoring {
    private let service: String

    public init(service: String = "ai.res.resai") {
        self.service = service
    }

    public func string(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setString(_ value: String, for account: String) throws {
        if value.isEmpty {
            try delete(account: account)
            return
        }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainStoreError.unexpectedStatus(status)
    }
}

/// Keeps secrets in memory only. Tests use it so a test run never reads or writes the
/// user's Keychain. Like `KeychainStore`, an empty value deletes the entry.
public final class InMemorySecretStore: SecretStringStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func string(for account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    public func setString(_ value: String, for account: String) throws {
        lock.withLock { values[account] = value.isEmpty ? nil : value }
    }
}
