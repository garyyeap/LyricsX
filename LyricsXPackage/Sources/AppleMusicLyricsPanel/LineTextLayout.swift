import AppKit
import CoreText
import LyricsXFoundation

extension AppleMusicLyrics {
    /// A lyric line laid out once by Core Text and sliced into the shape Apple
    /// Music animates: a list of words, each owning its glyphs.
    ///
    /// Music's model is `Line → Word → Syllable → Glyph`; we collapse the syllable
    /// level, because LyricsKit's inline time tags give per-word boundaries and
    /// nothing finer. Everything is in the line content layer's coordinate space,
    /// which is y-down (the layer sets `isGeometryFlipped`) so it lines up with the
    /// flipped view that hosts it.
    struct LineTextLayout {
        /// One glyph, positioned inside its word.
        struct Glyph {
            let run: CTRun
            let glyphRange: CFRange
            /// Frame in the owning word's coordinate space.
            let frame: CGRect
            /// The run's text origin relative to the glyph frame, so the layer can
            /// place the baseline without re-measuring.
            let textPosition: CGPoint
        }

        /// One word: the unit Music emphasizes, and the unit our time tags give us.
        struct Word {
            let text: String
            /// When this word is sung, in seconds from the start of the line.
            /// `nil` when the line carries no inline timing at all.
            let timeRange: Range<TimeInterval>?
            let glyphs: [Glyph]
            /// Frame in the line content layer's coordinate space.
            let frame: CGRect
            let visualLineIndex: Int

            /// Span of the phrase this word belongs to, and how many glyphs that
            /// phrase holds in total.
            ///
            /// Music's emphasis timings are written for words that carry several
            /// glyphs: the spring's period is the *word's* duration while each
            /// glyph starts travelling back after only `2 · duration / glyphCount`,
            /// so a glyph never reaches the top and its motion overlaps its
            /// neighbours' — that overlap is the travelling swell.
            ///
            /// Our inline time tags are per character, so left alone every word
            /// holds exactly one glyph, both of those terms degenerate (the return
            /// lands long after the spring has settled) and each character rises,
            /// freezes for about 0.6 s and drops on its own. Grouping neighbouring
            /// words back into a phrase puts Music's own formulas back in the range
            /// they were written for.
            var phraseDuration: TimeInterval = 0
            var phraseGlyphCount: Int = 1

            var duration: TimeInterval {
                guard let timeRange else { return 0 }
                return timeRange.upperBound - timeRange.lowerBound
            }
        }

        let words: [Word]
        /// Typographic width of each visual (wrapped) row.
        let visualLineWidths: [CGFloat]
        /// Left edge of each visual row's text, parallel to `visualLineWidths`.
        let visualLineLeftEdges: [CGFloat]
        let contentSize: CGSize

        var totalTextWidth: CGFloat {
            visualLineWidths.reduce(0, +)
        }
    }
}

extension AppleMusicLyrics.LineTextLayout {
    /// Lay `attributed` out and group its glyphs into words using `wordTimings`.
    ///
    /// `wordTimings` character indices are offsets into `content` counted in
    /// `Character`s (that is what LyricsKit's inline time tags carry), while Core
    /// Text reports string indices in UTF-16, so the two are reconciled here once
    /// rather than at every glyph.
    static func build(
        attributed: NSAttributedString,
        content: String,
        wordTimings: [AppleMusicLyrics.WordTimingEntry],
        lineDuration: TimeInterval,
        textWidth: CGFloat
    ) -> AppleMusicLyrics.LineTextLayout? {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGMutablePath()
        // Unbounded height: CTFrame only emits lines that fully fit the path, so a
        // height-bounded one silently drops the last visual row.
        path.addRect(CGRect(x: 0, y: 0, width: textWidth, height: 100_000))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        guard let coreTextLines = CTFrameGetLines(frame) as? [CTLine], !coreTextLines.isEmpty else { return nil }

        var lineOrigins = [CGPoint](repeating: .zero, count: coreTextLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &lineOrigins)

        // Core Text's path space is y-up; map every baseline into a y-down space
        // whose 0 is the top of the first row.
        var firstAscent: CGFloat = 0
        _ = CTLineGetTypographicBounds(coreTextLines[0], &firstAscent, nil, nil)
        let blockTopInPathSpace = lineOrigins[0].y + firstAscent

        let wordBoundaries = utf16WordBoundaries(content: content, wordTimings: wordTimings, lineDuration: lineDuration)

        var words: [Word] = []
        var visualLineWidths: [CGFloat] = []
        var visualLineLeftEdges: [CGFloat] = []
        var contentHeight: CGFloat = 0

        for (visualLineIndex, coreTextLine) in coreTextLines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(coreTextLine, &ascent, &descent, &leading))
            visualLineWidths.append(width)
            visualLineLeftEdges.append(lineOrigins[visualLineIndex].x)

            let baselineY = blockTopInPathSpace - lineOrigins[visualLineIndex].y
            contentHeight = max(contentHeight, baselineY + descent + leading)

            words.append(contentsOf: makeWords(
                in: coreTextLine,
                row: RowMetrics(
                    visualLineIndex: visualLineIndex,
                    leftEdge: lineOrigins[visualLineIndex].x,
                    baselineY: baselineY,
                    ascent: ascent,
                    descent: descent
                ),
                boundaries: wordBoundaries,
                content: content
            ))
        }

        assignPhrases(to: &words)

        return AppleMusicLyrics.LineTextLayout(
            words: words,
            visualLineWidths: visualLineWidths,
            visualLineLeftEdges: visualLineLeftEdges,
            contentSize: CGSize(width: textWidth, height: ceil(contentHeight))
        )
    }

    /// Gather neighbouring words into phrases, and tag each word with its
    /// phrase's span — see `Word.phraseDuration` for why the emphasis timings
    /// need this.
    ///
    /// A phrase ends at whitespace (the only word boundary the text itself
    /// gives us), at a wrap, at an untimed word, and once it has grown longer
    /// than the spring period Music is willing to use — past that the period
    /// stops growing with the phrase, so letting the phrase keep growing would
    /// only stretch the tail.
    private static func assignPhrases(to words: inout [Word]) {
        var phraseStart = 0

        func closePhrase(endingBefore end: Int) {
            defer { phraseStart = end }
            guard phraseStart < end else { return }
            let members = words[phraseStart ..< end]
            let glyphCount = members.reduce(0) { $0 + $1.glyphs.count }
            let span: TimeInterval
            if let start = members.first?.timeRange?.lowerBound,
               let finish = members.last?.timeRange?.upperBound {
                span = max(0, finish - start)
            } else {
                span = 0
            }
            for index in phraseStart ..< end {
                words[index].phraseDuration = span
                words[index].phraseGlyphCount = max(1, glyphCount)
            }
        }

        for index in words.indices {
            let word = words[index]
            let spanSoFar = words[phraseStart].timeRange.map { start in
                (word.timeRange?.upperBound ?? start.upperBound) - start.lowerBound
            } ?? 0
            let isLast = index + 1 == words.count
            let breaksHere = word.timeRange == nil
                || word.text.last?.isWhitespace == true
                || spanSoFar >= AppleMusicLyrics.LyricsSpecs.maximumEmphasisSpringPeriod
                || (!isLast && words[index + 1].visualLineIndex != word.visualLineIndex)
            if breaksHere {
                closePhrase(endingBefore: index + 1)
            }
        }
        closePhrase(endingBefore: words.count)
    }

    /// One word boundary, already converted to UTF-16 so it can be compared
    /// against Core Text's string indices directly.
    private struct WordBoundary {
        let utf16Range: Range<Int>
        let characterRange: Range<Int>
        let timeRange: Range<TimeInterval>?
    }

    private static func utf16WordBoundaries(
        content: String,
        wordTimings: [AppleMusicLyrics.WordTimingEntry],
        lineDuration: TimeInterval
    ) -> [WordBoundary] {
        var characterToUTF16: [Int] = []
        characterToUTF16.reserveCapacity(content.count + 1)
        var utf16Offset = 0
        for character in content {
            characterToUTF16.append(utf16Offset)
            utf16Offset += character.utf16.count
        }
        characterToUTF16.append(utf16Offset)

        let characterCount = content.count
        guard !wordTimings.isEmpty else {
            // No inline timing: the whole line behaves as a single word with no
            // emphasis schedule of its own.
            return [WordBoundary(utf16Range: 0 ..< utf16Offset, characterRange: 0 ..< characterCount, timeRange: nil)]
        }

        var boundaries: [WordBoundary] = []
        for (index, timing) in wordTimings.enumerated() {
            let startCharacter = min(max(0, timing.characterIndex), characterCount)
            let endCharacter = index + 1 < wordTimings.count
                ? min(max(startCharacter, wordTimings[index + 1].characterIndex), characterCount)
                : characterCount
            guard startCharacter < endCharacter else { continue }
            let endTime = index + 1 < wordTimings.count ? wordTimings[index + 1].timeOffset : lineDuration
            boundaries.append(WordBoundary(
                utf16Range: characterToUTF16[startCharacter] ..< characterToUTF16[endCharacter],
                characterRange: startCharacter ..< endCharacter,
                timeRange: timing.timeOffset ..< max(timing.timeOffset, endTime)
            ))
        }
        return boundaries
    }

    /// Slice one visual row's glyphs into words.
    ///
    /// A word that straddles a wrap becomes two entries sharing the same time
    /// range: Core Text can break anywhere in CJK text, and a single layer cannot
    /// span two rows.
    /// One glyph in row order, tagged with the word it belongs to.
    private struct TaggedGlyph {
        let boundaryIndex: Int
        let run: CTRun
        let glyphRange: CFRange
        /// Frame in the visual row's coordinate space, before the word it lands
        /// in is known and its origin can be subtracted out.
        let frame: CGRect
    }

    /// Everything about one visual row that its glyphs need.
    private struct RowMetrics {
        let visualLineIndex: Int
        let leftEdge: CGFloat
        let baselineY: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Slice one visual row's glyphs into words.
    ///
    /// A word that straddles a wrap becomes two entries sharing the same time
    /// range: Core Text can break anywhere in CJK text, and a single layer cannot
    /// span two rows.
    private static func makeWords(
        in coreTextLine: CTLine,
        row: RowMetrics,
        boundaries: [WordBoundary],
        content: String
    ) -> [Word] {
        let tagged = taggedGlyphs(in: coreTextLine, row: row, boundaries: boundaries)
        guard !tagged.isEmpty else { return [] }

        var result: [Word] = []
        var currentBoundary = tagged[0].boundaryIndex
        var currentGlyphs: [TaggedGlyph] = []

        func flush() {
            guard !currentGlyphs.isEmpty else { return }
            let wordFrame = currentGlyphs.dropFirst().reduce(currentGlyphs[0].frame) { $0.union($1.frame) }
            let boundary = boundaries.indices.contains(currentBoundary) ? boundaries[currentBoundary] : nil
            result.append(Word(
                text: boundary.map { text(of: $0, in: content) } ?? "",
                timeRange: boundary?.timeRange,
                glyphs: currentGlyphs.map { glyph in
                    Glyph(
                        run: glyph.run,
                        glyphRange: glyph.glyphRange,
                        frame: glyph.frame.offsetBy(dx: -wordFrame.minX, dy: -wordFrame.minY),
                        // `CTRunDraw` places a glyph at its own offset *within the
                        // run*, and the layer is already sitting at that offset, so
                        // the run origin has to be pulled back by the same amount or
                        // every glyph past the first draws outside its own bounds and
                        // is clipped away. Vertically the origin is the baseline,
                        // which sits `descent` up from the frame's bottom edge.
                        textPosition: CGPoint(x: row.leftEdge - glyph.frame.minX, y: -row.descent)
                    )
                },
                frame: wordFrame,
                visualLineIndex: row.visualLineIndex
            ))
            currentGlyphs = []
        }

        for glyph in tagged {
            if glyph.boundaryIndex != currentBoundary {
                flush()
                currentBoundary = glyph.boundaryIndex
            }
            currentGlyphs.append(glyph)
        }
        flush()
        return result
    }

    private static func taggedGlyphs(in coreTextLine: CTLine, row: RowMetrics, boundaries: [WordBoundary]) -> [TaggedGlyph] {
        guard let runs = CTLineGetGlyphRuns(coreTextLine) as? [CTRun] else { return [] }
        var tagged: [TaggedGlyph] = []
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)

            for glyphIndex in 0 ..< glyphCount {
                tagged.append(TaggedGlyph(
                    boundaryIndex: boundaries.firstIndex { $0.utf16Range.contains(stringIndices[glyphIndex]) } ?? 0,
                    run: run,
                    glyphRange: CFRange(location: glyphIndex, length: 1),
                    frame: CGRect(
                        x: row.leftEdge + positions[glyphIndex].x,
                        y: row.baselineY - row.ascent,
                        width: advances[glyphIndex].width,
                        height: row.ascent + row.descent
                    )
                ))
            }
        }
        return tagged
    }

    private static func text(of boundary: WordBoundary, in content: String) -> String {
        guard boundary.characterRange.lowerBound < content.count else { return "" }
        let start = content.index(content.startIndex, offsetBy: boundary.characterRange.lowerBound)
        let end = content.index(content.startIndex, offsetBy: min(boundary.characterRange.upperBound, content.count))
        return String(content[start ..< end])
    }
}
