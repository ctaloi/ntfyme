import Foundation
import Testing
@testable import NtfyKit

@Test func fileURLsAreRejected() {
    #expect(NtfyURLPolicy.sanitized("file:///etc/passwd") == nil)
}

@Test func customSchemeURLsAreRejected() {
    #expect(NtfyURLPolicy.sanitized("myapp://do-something") == nil)
}

@Test func httpsURLsSurvive() {
    #expect(NtfyURLPolicy.sanitized("https://example.com/path") == URL(string: "https://example.com/path"))
}

@Test func httpURLsSurvive() {
    #expect(NtfyURLPolicy.sanitized("http://example.com") == URL(string: "http://example.com"))
}

@Test func nilAndUnparseableInputAreRejected() {
    #expect(NtfyURLPolicy.sanitized(nil) == nil)
    #expect(NtfyURLPolicy.sanitized("") == nil)
}
