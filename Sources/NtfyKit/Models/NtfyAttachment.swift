import Foundation

public struct NtfyAttachment: Codable, Sendable, Equatable {
    public let name: String
    public let url: String
    public let type: String?
    public let size: Int?
    public let expires: Int?
}
