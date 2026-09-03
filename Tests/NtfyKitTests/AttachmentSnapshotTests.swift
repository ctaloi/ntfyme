import Foundation
import Testing
@testable import NtfyKit

@Test func aMessageWithNoAttachmentHasANilAttachmentSnapshot() {
    let message = Message(serverID: UUID(), topic: "alerts", messageID: "a",
                          time: Date(timeIntervalSince1970: 1), body: "body")
    #expect(message.snapshot.attachment == nil)
}

@Test func anAttachmentSnapshotRoundTripsMetadataWithNilLocalFilenameWhenUndownloaded() {
    let attachment = Attachment(name: "report.pdf", urlString: "https://example.com/report.pdf",
                                type: "application/pdf", size: 4096, localFilename: nil)
    let message = Message(serverID: UUID(), topic: "alerts", messageID: "a",
                          time: Date(timeIntervalSince1970: 1), body: "body",
                          attachment: attachment)
    let snapshot = message.snapshot.attachment
    #expect(snapshot?.name == "report.pdf")
    #expect(snapshot?.type == "application/pdf")
    #expect(snapshot?.size == 4096)
    #expect(snapshot?.localFilename == nil)
}

@Test func anAttachmentSnapshotCarriesLocalFilenameOnceDownloaded() {
    let attachment = Attachment(name: "report.pdf", urlString: "https://example.com/report.pdf",
                                type: "application/pdf", size: 4096, localFilename: "abc123.pdf")
    let message = Message(serverID: UUID(), topic: "alerts", messageID: "a",
                          time: Date(timeIntervalSince1970: 1), body: "body",
                          attachment: attachment)
    #expect(message.snapshot.attachment?.localFilename == "abc123.pdf")
}
