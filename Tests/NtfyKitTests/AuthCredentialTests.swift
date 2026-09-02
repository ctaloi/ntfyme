import Foundation
import Testing
@testable import NtfyKit

@Test func noneProducesNoHeader() {
    #expect(AuthCredential.unauthenticated.authorizationHeader == nil)
}

@Test func bearerProducesABearerHeader() {
    #expect(AuthCredential.bearer(token: "tk_abc").authorizationHeader == "Bearer tk_abc")
}

@Test func basicProducesBase64OfUserColonPassword() {
    let header = AuthCredential.basic(user: "phil", password: "s3cret").authorizationHeader
    #expect(header == "Basic " + Data("phil:s3cret".utf8).base64EncodedString())
}
