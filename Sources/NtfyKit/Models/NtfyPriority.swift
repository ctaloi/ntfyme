import Foundation

/// ntfy message priority. The wire format is 1...5; anything else is invalid.
public enum NtfyPriority: Int, Sendable, CaseIterable, Codable {
    case min = 1
    case low = 2
    case `default` = 3
    case high = 4
    case max = 5
}
