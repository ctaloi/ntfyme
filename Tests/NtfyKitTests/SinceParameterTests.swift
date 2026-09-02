import Testing
@testable import NtfyKit

@Test func encodesQueryValues() {
    #expect(SinceParameter.all.queryValue == "all")
    #expect(SinceParameter.unixTime(1_788_353_322).queryValue == "1788353322")
    #expect(SinceParameter.messageID("J7rfOekQUOkP").queryValue == "J7rfOekQUOkP")
    #expect(SinceParameter.duration("48h").queryValue == "48h")
}
