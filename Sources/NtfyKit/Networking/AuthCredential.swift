import Foundation

/// How to authenticate to one server. Values come from the Keychain and are
/// never persisted in the message store or written to logs.
public enum AuthCredential: Sendable, Equatable {
    /// No credential. Named `unauthenticated` rather than `none` because this
    /// type is held as `AuthCredential?` downstream, where `.none` would be
    /// ambiguous with `Optional.none` at every call site.
    case unauthenticated
    case bearer(token: String)
    case basic(user: String, password: String)

    public var authorizationHeader: String? {
        switch self {
        case .unauthenticated:
            nil
        case .bearer(let token):
            "Bearer \(token)"
        case .basic(let user, let password):
            "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
    }
}
