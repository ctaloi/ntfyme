import Foundation

/// The seam between `ServerConnection` and the network.
///
/// `ServerConnection` took a concrete `NtfyStreamClient`, which meant every
/// state-machine test needed a real socket and timing-based polling. This
/// protocol lets the persistence and coordinator layers assert transitions
/// deterministically, in process.
public protocol StreamClient: Sendable {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<NtfyStreamClient.StreamElement, Swift.Error>
}

extension NtfyStreamClient: StreamClient {}
