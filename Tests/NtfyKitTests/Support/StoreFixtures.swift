import Foundation
import SwiftData
@testable import NtfyKit

enum StoreFixtures {
    /// In-memory container. Each call gets its own store, so tests never share
    /// state and never touch the user's real database.
    static func inMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Message.self, Subscription.self,
                                  Server.self, Attachment.self,
                                  configurations: config)
    }
}
