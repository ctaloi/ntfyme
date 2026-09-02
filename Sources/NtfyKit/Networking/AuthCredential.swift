import Foundation

/// How to authenticate to one server. Values come from the Keychain and are
/// never persisted in the message store or written to logs.
public enum AuthCredential: Sendable, Equatable {
    case none
    case bearer(token: String)
    case basic(user: String, password: String)

    public var authorizationHeader: String? {
        switch self {
        case .none:
            nil
        case .bearer(let token):
            "Bearer \(token)"
        case .basic(let user, let password):
            "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
    }
}
