import Foundation
import Security

/// Stores one credential per server in the login keychain.
///
/// Credentials live only here — never in the message store, never in an export,
/// never in a log (spec §9). The account name is the server's UUID, so nothing
/// identifying the server's hostname is written either.
public struct KeychainStore: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unhandled(status: OSStatus)
        case malformedData
    }

    private let service: String

    public init(service: String = "dev.aloi.NtfyMe") {
        self.service = service
    }

    public func save(_ credential: AuthCredential, forServer id: UUID) throws {
        guard let payload = Self.encode(credential) else {
            try delete(forServer: id)
            return
        }

        try delete(forServer: id)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.unhandled(status: status) }
    }

    public func load(forServer id: UUID) throws -> AuthCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecItemNotFound:
            return .none
        case errSecSuccess:
            guard let data = result as? Data else { throw Error.malformedData }
            guard let credential = Self.decode(data) else { throw Error.malformedData }
            return credential
        default:
            throw Error.unhandled(status: status)
        }
    }

    public func delete(forServer id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unhandled(status: status)
        }
    }

    // MARK: - Encoding

    private struct Stored: Codable {
        let kind: String
        let a: String
        let b: String?
    }

    private static func encode(_ credential: AuthCredential) -> Data? {
        let stored: Stored
        switch credential {
        case .none:
            return nil
        case .bearer(let token):
            stored = Stored(kind: "bearer", a: token, b: nil)
        case .basic(let user, let password):
            stored = Stored(kind: "basic", a: user, b: password)
        }
        return try? JSONEncoder().encode(stored)
    }

    private static func decode(_ data: Data) -> AuthCredential? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        switch stored.kind {
        case "bearer":
            return .bearer(token: stored.a)
        case "basic":
            guard let password = stored.b else { return nil }
            return .basic(user: stored.a, password: password)
        default:
            return nil
        }
    }
}
