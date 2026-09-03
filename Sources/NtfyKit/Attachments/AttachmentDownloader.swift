import Foundation

/// Downloads an ntfy message's attachment to local storage.
///
/// On public ntfy.sh, anyone who knows a topic name can publish to it (spec
/// §9 — a topic name is effectively a password), so an attachment's `url`,
/// `name`, and `type` are all attacker-controlled input, not trusted server
/// values, and are treated that way throughout this type — see
/// `NotificationDecision`'s header for the same reasoning applied to
/// notification content.
public actor AttachmentDownloader {
    public enum Error: Swift.Error, Equatable {
        /// `attachment.url` did not parse, or its scheme was not in
        /// `NotificationDecision.allowedURLSchemes`.
        case unsupportedScheme
        /// Either the response's `Content-Length` header, or the streamed
        /// body itself, exceeded `maximumBytes`. The associated value is
        /// whichever of those two was actually observed.
        case tooLarge(bytes: Int)
        /// The response's HTTP status was outside 200...299.
        case httpError(status: Int)
    }

    private let session: URLSession
    private let directory: URL
    private let maximumBytes: Int

    public init(session: URLSession = AttachmentDownloader.makeSession(),
                directory: URL,
                maximumBytes: Int = 25 * 1024 * 1024) {
        self.session = session
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    /// A dedicated session, not `.shared`: an attachment URL is
    /// attacker-chosen (see the type doc comment above), so the request
    /// must not ride the user's ambient credentials toward it. Same
    /// reasoning and the same explicit settings as
    /// `NotificationActionHandler`'s session in the app target — `.ephemeral`
    /// alone is not enough, since its own in-memory jar and credential store
    /// would still answer a cookie or a Basic/Digest challenge from the
    /// attacker's host — so every one of these is set explicitly rather than
    /// relying on what the base configuration happens to default to: no
    /// cookie storage, cookies from a response never accepted or stored, no
    /// credential storage to answer an auth challenge, and no additional
    /// headers merged in from anywhere else.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        return URLSession(configuration: configuration)
    }

    /// Downloads `attachment` into `directory` and returns the generated
    /// local filename — never the server-supplied `name`. See
    /// `generatedFilename` for why that matters.
    public func download(_ attachment: NtfyAttachment) async throws -> String {
        let url = try sanitizedURL(attachment.url)

        // Created up front so a caller that gets a filename back can rely on
        // the directory already existing; also means a request that fails
        // never leaves the directory in a half-created state to reason about.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Error.httpError(status: http.statusCode)
        }

        // `expectedContentLength` reflects the response's `Content-Length`
        // header when present, -1 when absent. This is a fast rejection for
        // the common case, not the enforcement itself — a server can send an
        // absent or dishonest header, so the loop below is what actually
        // bounds the download regardless of what the server claims.
        if response.expectedContentLength >= 0, response.expectedContentLength > Int64(maximumBytes) {
            throw Error.tooLarge(bytes: Int(response.expectedContentLength))
        }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes {
                // Stop pulling bytes off the wire the instant the cap is
                // crossed, rather than after the whole body has arrived —
                // the server is untrusted and may be trying to exhaust disk
                // or memory with an unbounded body.
                bytes.task.cancel()
                throw Error.tooLarge(bytes: data.count)
            }
        }

        let filename = Self.generatedFilename(name: attachment.name, type: attachment.type)
        let destination = directory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        return filename
    }

    /// `raw` is a wire value — see the type doc comment. Same allow-list as
    /// `NotificationDecision.allowedURLSchemes`: `file://` reads local
    /// files and a custom scheme can launch another app, so only the
    /// schemes a browser would treat as ordinary web content are accepted.
    private func sanitizedURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              NotificationDecision.allowedURLSchemes.contains(scheme)
        else { throw Error.unsupportedScheme }
        return url
    }

    /// A UUID, plus a sanitised extension when `name` or `type` yields one —
    /// never the server-supplied `name` itself, and never anything derived
    /// from it beyond a short alphanumeric suffix.
    ///
    /// A prior review found and fixed a path-traversal bug in
    /// `MessageStore.prune`, where a crafted `Attachment.localFilename`
    /// containing `../` escaped the attachments directory; the guard added
    /// there rejects a non-component name, which is necessary since nothing
    /// stopped an unsafe value from being stored in the first place. This is
    /// the actual fix for that: the only writer of `localFilename` never
    /// lets server input become a filename at all, so there is nothing for
    /// that guard to ever have to reject.
    static func generatedFilename(name: String, type: String?) -> String {
        let ext = sanitizedExtension(fromName: name) ?? sanitizedExtension(fromType: type)
        let uuid = UUID().uuidString
        guard let ext else { return uuid }
        return "\(uuid).\(ext)"
    }

    /// The full grammar of a valid extension this app will ever attach to a
    /// generated filename: 1 to 10 ASCII letters or digits. Anchored at both
    /// ends, so a candidate that merely contains a valid-looking substring
    /// (e.g. one with an embedded `/` or `..`) does not match.
    private static let extensionPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9]{1,10}$")

    private static func isValidExtension(_ candidate: String) -> Bool {
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return extensionPattern.firstMatch(in: candidate, range: range) != nil
    }

    /// Only ever reads the text after the last `.` in `name` — it is never
    /// joined back onto anything path-shaped, so a hostile name like
    /// `"../escape.txt"` or `"a/b.txt"` yields only the candidate `"txt"`,
    /// and only once that candidate itself passes `isValidExtension`.
    private static func sanitizedExtension(fromName name: String) -> String? {
        guard let lastDot = name.lastIndex(of: ".") else { return nil }
        let candidate = String(name[name.index(after: lastDot)...])
        return isValidExtension(candidate) ? candidate : nil
    }

    /// MIME types are `type/subtype`; the subtype is the closest thing to an
    /// extension. Same validation as the name-derived path above — a
    /// subtype carrying parameters (`"text/plain; charset=utf-8"`) simply
    /// fails `isValidExtension` and falls back to no extension, rather than
    /// being parsed further.
    private static func sanitizedExtension(fromType type: String?) -> String? {
        guard let type, let slash = type.lastIndex(of: "/") else { return nil }
        let candidate = String(type[type.index(after: slash)...])
        return isValidExtension(candidate) ? candidate : nil
    }
}
