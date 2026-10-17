import Foundation
import Security

public enum CredentialKey: String, CaseIterable, Sendable {
    case goAPIKey
    case relayToken
}

public protocol CredentialStoring: Sendable {
    func get(_ key: CredentialKey) throws -> String?
    func set(_ value: String, for key: CredentialKey) throws
    func remove(_ key: CredentialKey) throws
}

public enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "Keychain access failed: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))."
        case .invalidData: return "The saved credential could not be read."
        }
    }
}

public struct KeychainCredentialStore: CredentialStoring {
    public let service: String

    // Stable across display-name changes so existing saved keys remain accessible.
    public init(service: String = "dev.warpgobridge.app") { self.service = service }

    private func query(_ key: CredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key.rawValue]
    }

    public func get(_ key: CredentialKey) throws -> String? {
        var search = query(key)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw CredentialStoreError.invalidData }
        return value
    }

    public func set(_ value: String, for key: CredentialKey) throws {
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertion = SecItemAdd(item as CFDictionary, nil)
            guard insertion == errSecSuccess else { throw CredentialStoreError.keychain(insertion) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychain(status)
        }
    }

    public func remove(_ key: CredentialKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }

    public static func generateRelayToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
