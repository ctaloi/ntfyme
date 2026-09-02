import AppKit
import Foundation
import NtfyKit

/// Performs the action behind a notification button.
///
/// Deliberately contains no policy: which action a message maps to is
/// decided in `NotificationDecision`. This file only executes the result.
enum NotificationActionHandler {
    /// A dedicated session for `http` actions, not `.shared`: the target is
    /// attacker-chosen (see `NotificationDecision`'s header/method/scheme
    /// constraints), so the request must not ride the user's ambient
    /// credentials toward it. `.ephemeral` alone is not enough to guarantee
    /// that — its own in-memory jar and credential store would still answer
    /// a cookie or a Basic/Digest challenge from the attacker's host — so
    /// every one of these is set explicitly rather than relying on what the
    /// base configuration happens to default to: no cookie storage, cookies
    /// from a response never accepted or stored, no credential storage to
    /// answer an auth challenge, and no additional headers merged in from
    /// anywhere else.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        return URLSession(configuration: configuration)
    }()

    static func perform(_ action: PresentableAction) async {
        switch action.kind {
        case .view(let url):
            NSWorkspace.shared.open(url)

        case .copy(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)

        case .http(let url, let method, let headers, let body):
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            if let body { request.httpBody = Data(body.utf8) }
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Reported, not swallowed: a user pressing a button deserves to
                // know it failed. The URL is never logged — it is server-supplied.
                Log.app.info("notification http action returned \(status, privacy: .public)")
            } catch {
                let ns = error as NSError
                Log.app.error("notification http action failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            }
        }
    }

    static func openClickURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
