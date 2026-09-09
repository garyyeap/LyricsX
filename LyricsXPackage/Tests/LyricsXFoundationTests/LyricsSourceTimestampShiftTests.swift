import Testing
@testable import LyricsXFoundation

@Test func sourceShiftPreservesLRCXContent() {
    let source = "[ar:Artist]\r\n[offset:200]\r\n[00:10.00][00:20.000]Hello 😀\r\n[00:10.000][tr:en]Translation\r\n[00:10.000][tt]<0,0><500,2>\r\n"
    let expected = "[ar:Artist]\r\n\r\n[00:09.500][00:19.500]Hello 😀\r\n[00:09.500][tr:en]Translation\r\n[00:09.500][tt]<0,0><500,2>\r\n"
    #expect(LyricsSourceTimestampShift.applying(offset: 500, to: source) == expected)
}

@Test func sourceShiftPreservesLRCContent() {
    #expect(LyricsSourceTimestampShift.applying(offset: -1000, to: "[00:59.500]Text") == "[01:00.500]Text")
    #expect(LyricsSourceTimestampShift.applying(offset: 500, to: "[00:00.100]Text") == "[00:00.000]Text")
}

@Test func sourceShiftLeavesTimestampLikeTextAlone() {
    #expect(LyricsSourceTimestampShift.applying(offset: 500, to: "[00:10.000]Sing [00:20.000] literally [offset:200]") == "[00:09.500]Sing [00:20.000] literally [offset:200]")
}

@Test func sourceShiftMatchesLyricsKitTimestampGrammar() {
    #expect(LyricsSourceTimestampShift.applying(offset: 500, to: "[00:1.5]First\n[+00:10.1234]Second") == "[00:01.000]First\n[00:09.6234]Second")
}

@Test func lrcxWordTimingMovesWithItsLine() throws {
    let source = "[00:10.000]Hello\n[00:10.000][tt]<0,0><500,2><1000>"
    let shifted = LyricsSourceTimestampShift.applying(offset: 500, to: source)
    let lyrics = try #require(Lyrics(shifted))
    let line = try #require(lyrics.lines.first)
    let timing = try #require(line.attachments.timetag)
    #expect(line.position == 9.5)
    #expect(timing.tags[1].time == 0.5)
    #expect(line.position + timing.tags[1].time == 10)
    #expect(timing.duration == 1)
}
