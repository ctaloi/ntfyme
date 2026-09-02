import Testing
@testable import NtfyKit

@Test func kitExposesAVersion() {
    #expect(!NtfyKit.version.isEmpty)
}
