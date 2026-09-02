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
        guard let payload = try Self.encode(credential) else {
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
        let primary: String
        let secondary: String?
    }

    /// Returns `nil` only for `.none` — nothing to store, which `save`
    /// interprets as "delete any existing credential". A genuine encoding
    /// failure must never collapse to that same `nil`, or a real credential
    /// that failed to encode would silently vanish exactly as if the caller
    /// had asked to clear it. So encoding failure throws `.malformedData`
    /// instead of returning `nil`. `Stored`'s fields are plain
    /// `String`/`String?`, which `JSONEncoder` cannot fail to encode in
    /// practice, but the distinction is structural, not just documentation:
    /// even if that ever changed, callers could not mistake one case for
    /// the other.
    private static func encode(_ credential: AuthCredential) throws -> Data? {
        let stored: Stored
        switch credential {
        case .none:
            return nil
        case .bearer(let token):
            stored = Stored(kind: "bearer", primary: token, secondary: nil)
        case .basic(let user, let password):
            stored = Stored(kind: "basic", primary: user, secondary: password)
        }
        do {
            return try JSONEncoder().encode(stored)
        } catch {
            throw Error.malformedData
        }
    }

    /// A decoding failure (malformed bytes, unrecognized `kind`, a missing
    /// `secondary` for `basic`) is collapsed to `nil` rather than propagated
    /// with the underlying `Swift.Error`: `load` already turns `nil` into
    /// `Error.malformedData`, which is the only distinction its callers need.
    /// The specific decoding failure reason is not actionable, and keychain
    /// payload contents should not end up embedded in a thrown error.
    private static func decode(_ data: Data) -> AuthCredential? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        switch stored.kind {
        case "bearer":
            return .bearer(token: stored.primary)
        case "basic":
            guard let password = stored.secondary else { return nil }
            return .basic(user: stored.primary, password: password)
        default:
            return nil
        }
    }
}
