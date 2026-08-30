import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

@MainActor
struct LineEmphasisStructureProbes {
    private static let copyrightLine = "（未经著作权人许可，不得翻唱翻录或使用。）"

    private static func makeLayout(
        text: String,
        timing: LyricsLine.Attachments.SynchronizedTextTiming
    ) -> AppleMusicLyrics.LineTextLayout? {
        let attributedString = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        return AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: text,
            wordTimings: [],
            synchronizedTextTiming: timing,
            languageIdentifier: "en",
            lineDuration: timing.duration ?? 0,
            textWidth: 460
        )
    }

    private static func wordLayers(
        of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> [CALayer] {
        guard let maskContainer = contentLayer.mask else { return [] }
        return (maskContainer.sublayers ?? []).compactMap(\.mask)
    }

    private static func glyphLayers(
        of contentLayer: AppleMusicLyrics.SyncedLyricsLineContentLayer
    ) -> [CALayer] {
        wordLayers(of: contentLayer).flatMap { $0.sublayers ?? [] }
    }

    @Test func glowLivesOnRasterizedWordLayersAndResetRemovesIt() throws {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [.init(characterRange: 0 ..< 5, timeRange: 0 ..< 2)],
            duration: 2
        )
        let layout = try #require(Self.makeLayout(text: "Hello", timing: timing))
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)

        let wordLayers = Self.wordLayers(of: contentLayer)
        let glyphLayers = Self.glyphLayers(of: contentLayer)
        #expect(!wordLayers.isEmpty)
        #expect(wordLayers.allSatisfy { $0.shouldRasterize })
        #expect(wordLayers.allSatisfy { $0.rasterizationScale == 2 })
        #expect(wordLayers.allSatisfy { $0.shadowRadius == AppleMusicLyrics.LyricsSpecs.glowRadius })
        #expect(glyphLayers.allSatisfy { $0.shadowColor == nil && $0.shadowOpacity == 0 })

        contentLayer.update(elapsedTime: 0, fillFraction: 0)
        let firstWordLayer = try #require(wordLayers.first)
        #expect(firstWordLayer.shadowOpacity == AppleMusicLyrics.LyricsSpecs.glowOpacityRange.upperBound)
        #expect(firstWordLayer.animation(forKey: "AppleMusicLyrics.shadowOpacity") is CASpringAnimation)

        contentLayer.resetEmphasis()
        #expect(firstWordLayer.shadowOpacity == AppleMusicLyrics.LyricsSpecs.glowOpacityRange.lowerBound)
        #expect(firstWordLayer.animation(forKey: "AppleMusicLyrics.shadowOpacity") == nil)
        #expect(glyphLayers.allSatisfy { $0.animationKeys()?.isEmpty != false })
    }

    @Test func seekWithinTheSelectedLineResynchronizesTheActiveWord() throws {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(characterRange: 0 ..< 5, timeRange: 0 ..< 2),
                .init(characterRange: 5 ..< 10, timeRange: 2 ..< 4),
            ],
            duration: 4
        )
        let layout = try #require(Self.makeLayout(text: "HelloWorld", timing: timing))
        let contentLayer = AppleMusicLyrics.SyncedLyricsLineContentLayer()
        contentLayer.isHighlighted = true
        contentLayer.rebuild(with: layout, contentsScale: 2)
        let wordLayers = Self.wordLayers(of: contentLayer)
        #expect(wordLayers.count == 2)

        contentLayer.update(elapsedTime: 2.5, fillFraction: 0.625)
        #expect(wordLayers[0].animation(forKey: "AppleMusicLyrics.shadowOpacity") == nil)
        #expect(wordLayers[1].animation(forKey: "AppleMusicLyrics.shadowOpacity") is CASpringAnimation)

        contentLayer.update(elapsedTime: 0.5, fillFraction: 0.125)
        #expect(wordLayers[0].animation(forKey: "AppleMusicLyrics.shadowOpacity") is CASpringAnimation)
        #expect(wordLayers[1].animation(forKey: "AppleMusicLyrics.shadowOpacity") == nil)
    }

    @Test func wrappedRowsRemainInLogicalTopToBottomOrderInsideTheLineView() throws {
        let mainFontSize: CGFloat = 48
        let rowWidth: CGFloat = 620
        let attributedString = NSAttributedString(
            string: Self.copyrightLine,
            attributes: [.font: NSFont.systemFont(ofSize: mainFontSize, weight: .bold)]
        )
        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: Self.copyrightLine,
            wordTimings: [],
            lineDuration: 4,
            textWidth: rowWidth - 48
        ))
        #expect(layout.visualLineWidths.count == 2)
        let firstVisualRowMinimumVerticalPosition = try #require(
            layout.words.filter { $0.visualLineIndex == 0 }.map(\.frame.minY).min()
        )
        let secondVisualRowMinimumVerticalPosition = try #require(
            layout.words.filter { $0.visualLineIndex == 1 }.map(\.frame.minY).min()
        )
        #expect(firstVisualRowMinimumVerticalPosition < secondVisualRowMinimumVerticalPosition)

        let lyrics = try #require(Lyrics("[00:00.000]\(Self.copyrightLine)"))
        let lineView = AppleMusicLyrics.SyncedLyricsLineView(
            frame: NSRect(x: 0, y: 0, width: rowWidth, height: 300)
        )
        try lineView.configure(
            line: #require(lyrics.lines.first),
            originalIndex: 0,
            enabledPosition: 0,
            mainFontSize: mainFontSize,
            translationFontSize: 18
        )
        lineView.frame.size.height = lineView.preferredHeight(forWidth: rowWidth)
        lineView.layoutSubtreeIfNeeded()

        let contentLayer = try #require(
            lineView.layer?.sublayers?.compactMap {
                $0 as? AppleMusicLyrics.SyncedLyricsLineContentLayer
            }.first
        )
        #expect(
            contentLayer.isGeometryFlipped,
            "the content layer must preserve the y-down coordinates produced by LineTextLayout"
        )
        let glyphMaskContainer = try #require(contentLayer.mask)
        #expect(
            glyphMaskContainer.isGeometryFlipped,
            "the mask container that positions wrapped words must use the same y-down coordinates"
        )
    }
}
