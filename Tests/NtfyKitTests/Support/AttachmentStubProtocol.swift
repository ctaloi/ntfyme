import Foundation
import NtfyKit

/// A canned HTTP response for one URL, served without touching the network.
struct AttachmentStub: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    /// Sent as separate `didLoad` calls, so a downloader that reads the
    /// stream incrementally sees genuinely separate chunks rather than one
    /// call carrying the whole body.
    var bodyChunks: [Data] = []
}

/// Thread-safe registry `AttachmentStubProtocol` reads from. `URLProtocol`
/// callbacks run on a session-internal queue, not the calling test's, so a
/// bare `static var` would race with the test thread registering or
/// resetting stubs.
final class AttachmentStubRegistry: @unchecked Sendable {
    static let shared = AttachmentStubRegistry()

    private let lock = NSLock()
    private var stubs: [URL: AttachmentStub] = [:]

    func register(_ stub: AttachmentStub, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = stub
    }

    func stub(for url: URL) -> AttachmentStub? {
        lock.lock(); defer { lock.unlock() }
        return stubs[url]
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
    }
}

/// A `URLProtocol` that serves `AttachmentStubRegistry` entries instead of
/// making a real request, so `AttachmentDownloader` tests never touch the
/// network. Install it on a session via
/// `URLSessionConfiguration.protocolClasses`.
final class AttachmentStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return AttachmentStubRegistry.shared.stub(for: url) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = AttachmentStubRegistry.shared.stub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.bodyChunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Nothing to tear down: `startLoading()` delivers everything
        // synchronously before this could ever be called mid-flight, except
        // when the downloader cancels the task after an oversize body,
        // which is exactly what `stopLoading` exists to be a safe no-op for.
    }
}

extension AttachmentDownloader {
    /// A session wired to `AttachmentStubProtocol` instead of the network.
    static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttachmentStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}
