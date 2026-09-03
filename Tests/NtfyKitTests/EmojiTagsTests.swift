import Testing
@testable import NtfyKit

/// ntfy's emoji tag convention, and the reason it needed implementing: a
/// message published with `--tags warning,telephone_receiver` arrived in
/// this app as two text chips reading "warning" and "telephone_receiver",
/// which is how it was reported ("I see what looks like icon tags").

@Test func theReportedTagsAreBothEmoji() {
    let split = NtfyEmoji.split(tags: ["warning", "telephone_receiver"])
    #expect(split.emoji == ["⚠️", "📞"])
    #expect(split.labels.isEmpty)
}

@Test func nonEmojiTagsStayLabels() {
    let split = NtfyEmoji.split(tags: ["sil:100703648", "prod"])
    #expect(split.emoji.isEmpty)
    #expect(split.labels == ["sil:100703648", "prod"])
}

/// Order is preserved within each list, not just membership: ntfy renders
/// emoji in tag order, and a caller joining them has to get the publisher's
/// order rather than a dictionary's.
@Test func bothListsKeepTagOrder() {
    let split = NtfyEmoji.split(tags: ["rocket", "backend", "warning", "api"])
    #expect(split.emoji == ["🚀", "⚠️"])
    #expect(split.labels == ["backend", "api"])
}

@Test func matchingIsCaseInsensitive() {
    #expect(NtfyEmoji.split(tags: ["WARNING"]).emoji == ["⚠️"])
    #expect(NtfyEmoji.emoji(forShortCode: "Rocket") == "🚀")
}

@Test func anUnknownShortCodeIsNil() {
    #expect(NtfyEmoji.emoji(forShortCode: "definitely_not_an_emoji") == nil)
}

@Test func noTagsAtAllIsTwoEmptyLists() {
    let split = NtfyEmoji.split(tags: [])
    #expect(split.emoji.isEmpty)
    #expect(split.labels.isEmpty)
}

/// A generated table (see `EmojiTags.swift`) is only as good as its parse.
/// This pins that every line of the packed string became an entry — an
/// off-by-one in the generator or a mangled separator would show up here as
/// a smaller count rather than as a mysteriously missing emoji months later.
@Test func theWholeGeneratedTableParsed() {
    #expect(NtfyEmoji.table.count == 1913)
    // Spot checks across the file: first line, last line, and one with a
    // multi-scalar emoji (a base character plus a variation selector), which
    // is the case a naive character-based parse would truncate.
    #expect(NtfyEmoji.emoji(forShortCode: "+1") == "👍")
    #expect(NtfyEmoji.emoji(forShortCode: "zzz") == "💤")
    #expect(NtfyEmoji.emoji(forShortCode: "warning") == "⚠️")
    #expect(NtfyEmoji.emoji(forShortCode: "warning")?.unicodeScalars.count == 2)
}
