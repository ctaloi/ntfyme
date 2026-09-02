import Foundation

/// Spec §8: keep N days AND at most M messages per topic, whichever bound is
/// hit first.
public struct RetentionPolicy: Sendable, Equatable {
    public let maxAge: TimeInterval
    public let maxMessagesPerTopic: Int

    public static let `default` = RetentionPolicy(maxAge: 30 * 86_400,
                                                  maxMessagesPerTopic: 10_000)

    public init(maxAge: TimeInterval, maxMessagesPerTopic: Int) {
        self.maxAge = maxAge
        self.maxMessagesPerTopic = maxMessagesPerTopic
    }
}

public struct PruneResult: Sendable, Equatable {
    public let messagesDeleted: Int
    public let attachmentFilesDeleted: Int
}
