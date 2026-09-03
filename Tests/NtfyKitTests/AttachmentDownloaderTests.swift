import Foundation
import Testing
@testable import NtfyKit

private func attachment(name: String, url: String, type: String? = nil) -> NtfyAttachment {
    NtfyAttachment(name: name, url: url, type: type, size: nil, expires: nil)
}

/// A fresh, not-yet-existing directory under the system temp dir. Deliberately
/// not created here: `AttachmentDownloader.download` must create it itself.
private func freshDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ntfyme-attachments-\(UUID().uuidString)")
}

// MARK: - Filenames are generated, never taken from the server (spec: path
// traversal fix in MessageStore.prune). Every attachment name and type below
// is attacker input — see AttachmentDownloader's header.

@Test func downloadIgnoresAHostileNameContainingPathTraversal() async throws {
    let url = URL(string: "https://example.com/a")!
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: [:], bodyChunks: [Data("hi".utf8)]), for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 100)
    let filename = try await downloader.download(
        attachment(name: "../../escape.txt", url: url.absoluteString))

    #expect(!filename.contains("/"))
    #expect(!filename.contains(".."))
    // The file must land directly inside `dir`, not have escaped it.
    let expected = dir.appendingPathComponent(filename)
    #expect(FileManager.default.fileExists(atPath: expected.path))
    #expect(try Data(contentsOf: expected) == Data("hi".utf8))
}

@Test func downloadIgnoresAHostileNameContainingASlash() async throws {
    let url = URL(string: "https://example.com/b")!
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: [:], bodyChunks: [Data("hi".utf8)]), for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 100)
    let filename = try await downloader.download(attachment(name: "evil/name.txt", url: url.absoluteString))

    #expect(!filename.contains("/"))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(filename).path))
}

@Test func downloadPreservesASanitizedExtensionFromTheName() async throws {
    let url = URL(string: "https://example.com/c")!
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: [:], bodyChunks: [Data("hi".utf8)]), for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 100)
    let filename = try await downloader.download(attachment(name: "photo.png", url: url.absoluteString))

    #expect(filename.hasSuffix(".png"))
    // The stem is a UUID, not "photo" — the name itself never survives.
    #expect(!filename.hasPrefix("photo"))
}

@Test func downloadFallsBackToTheMIMETypeWhenTheNameHasNoValidExtension() async throws {
    let url = URL(string: "https://example.com/d")!
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: [:], bodyChunks: [Data("hi".utf8)]), for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 100)
    let filename = try await downloader.download(
        attachment(name: "../noextension", url: url.absoluteString, type: "image/jpeg"))

    #expect(filename.hasSuffix(".jpeg"))
}

@Test func downloadHasNoExtensionWhenNeitherNameNorTypeYieldOne() async throws {
    let url = URL(string: "https://example.com/e")!
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: [:], bodyChunks: [Data("hi".utf8)]), for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 100)
    let filename = try await downloader.download(
        attachment(name: "noextensionatall", url: url.absoluteString, type: "text/plain; charset=utf-8"))

    #expect(!filename.contains("."))
    #expect(UUID(uuidString: filename) != nil)
}

// MARK: - Scheme rejection

@Test func downloadRejectsAFileSchemeURLAndWritesNothing() async throws {
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 100)

    await #expect(throws: AttachmentDownloader.Error.unsupportedScheme) {
        _ = try await downloader.download(attachment(name: "a.txt", url: "file:///etc/passwd"))
    }
    // Rejected before any directory or file work happens.
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test func downloadRejectsAJavascriptSchemeURL() async throws {
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 100)

    await #expect(throws: AttachmentDownloader.Error.unsupportedScheme) {
        _ = try await downloader.download(attachment(name: "a.txt", url: "javascript:alert(1)"))
    }
}

// MARK: - Oversize rejection

@Test func downloadRejectsAnOversizeBodyDeclaredByContentLength() async throws {
    let url = URL(string: "https://example.com/f")!
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: ["Content-Length": "11"],
                       bodyChunks: [Data(repeating: 0x41, count: 11)]),
        for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 10)

    await #expect(throws: AttachmentDownloader.Error.tooLarge(bytes: 11)) {
        _ = try await downloader.download(attachment(name: "a.txt", url: url.absoluteString))
    }
    // The directory is created (download always creates it up front), but
    // it must be empty: nothing was written for a rejected download.
    let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(contents?.isEmpty != false)
}

@Test func downloadRejectsABodyThatExceedsTheCapWithNoHonestContentLength() async throws {
    let url = URL(string: "https://example.com/g")!
    // No Content-Length header at all — the fast-path check has nothing to
    // reject on, so only the streaming check can catch this.
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: [:],
                       bodyChunks: [Data(repeating: 0x41, count: 6), Data(repeating: 0x42, count: 6)]),
        for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 10)

    await #expect(throws: AttachmentDownloader.Error.tooLarge(bytes: 11)) {
        _ = try await downloader.download(attachment(name: "a.txt", url: url.absoluteString))
    }
    let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(contents?.isEmpty != false)
}

@Test func downloadRejectsABodyThatExceedsTheCapWithADishonestlySmallContentLength() async throws {
    let url = URL(string: "https://example.com/h")!
    // The header lies and claims a small body; the loop must still catch
    // the real, larger one.
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: ["Content-Length": "1"],
                       bodyChunks: [Data(repeating: 0x41, count: 50)]),
        for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 10)

    await #expect(throws: AttachmentDownloader.Error.tooLarge(bytes: 11)) {
        _ = try await downloader.download(attachment(name: "a.txt", url: url.absoluteString))
    }
}

// MARK: - HTTP status

@Test func downloadRejectsANonSuccessStatus() async throws {
    let url = URL(string: "https://example.com/i")!
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 404, headers: [:], bodyChunks: [Data("not found".utf8)]), for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 100)

    await #expect(throws: AttachmentDownloader.Error.httpError(status: 404)) {
        _ = try await downloader.download(attachment(name: "a.txt", url: url.absoluteString))
    }
}

// MARK: - Happy path

@Test func downloadCreatesTheDirectoryAndWritesTheExactBody() async throws {
    let url = URL(string: "https://example.com/j")!
    let body = Data("the attachment body".utf8)
    AttachmentStubRegistry.shared.register(
        AttachmentStub(status: 200, headers: ["Content-Length": "\(body.count)"], bodyChunks: [body]),
        for: url)
    let dir = freshDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!FileManager.default.fileExists(atPath: dir.path))

    let downloader = AttachmentDownloader(
        session: AttachmentDownloader.stubbedSession(), directory: dir, maximumBytes: 1024)
    let filename = try await downloader.download(attachment(name: "note.txt", url: url.absoluteString))

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(try Data(contentsOf: dir.appendingPathComponent(filename)) == body)
}
