import AppKit
import LyricsXFoundation
import Testing
@testable import AppleMusicLyricsPanel

struct AnimationPlanTests {
    @Test(arguments: ["ar", "ar-SA", "he_IL", "zh-Hant", "ja-JP"])
    func excludedLanguagesKeepLiftButRemoveScaleAndGlow(languageIdentifier: String) {
        let plan = AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 1.5,
            wordLength: 4,
            renderedGlyphCount: 4,
            timingGlyphCount: 4,
            languageIdentifier: languageIdentifier,
            timingSource: .synchronized
        )

        #expect(plan.factor == 0)
        #expect(plan.scale == 1)
        #expect(plan.glowOpacity == 0)
        #expect(plan.riseDelays.count == 4, "a zero factor must not remove the lift schedule")
    }

    @Test func synchronizedFactorUsesStrictDurationAndLengthBoundaries() {
        func factor(duration: TimeInterval, length: Int) -> CGFloat {
            AppleMusicLyrics.WordEmphasisPlan.make(
                wordDuration: duration,
                wordLength: length,
                renderedGlyphCount: length,
                timingGlyphCount: length,
                languageIdentifier: "en-US",
                timingSource: .synchronized
            ).factor
        }

        #expect(factor(duration: 1, length: 7) == 0)
        #expect(abs(factor(duration: 1.25, length: 7) - 0.25) < 0.000_001)
        #expect(factor(duration: 2, length: 7) == 1)
        #expect(factor(duration: 8, length: 7) == 1)
        #expect(factor(duration: 2, length: 8) == 0)
    }

    @Test func synchronizedScheduleUsesTheRecoveredWordFormulas() {
        let plan = AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 2,
            wordLength: 4,
            renderedGlyphCount: 4,
            timingGlyphCount: 4,
            languageIdentifier: nil,
            timingSource: .synchronized
        )

        #expect(plan.factor == 1)
        #expect(abs(plan.scale - 1.14) < 0.000_001)
        #expect(abs(plan.glowOpacity - 0.4) < 0.000_001)
        #expect(plan.springPeriod == 2)
        #expect(abs(plan.glyphStagger - 0.2) < 0.000_001)
        #expect(zip(plan.riseDelays, [0.2, 0.4, 0.6, 0.8]).allSatisfy { actualValue, expectedValue in
            abs(actualValue - expectedValue) < 0.000_001
        })
        #expect(zip(plan.returnDelays, [1.2, 1.4, 1.6, 1.8]).allSatisfy { actualValue, expectedValue in
            abs(actualValue - expectedValue) < 0.000_001
        })
        #expect(plan.deglowDelay == 2)
        #expect(AppleMusicLyrics.WordEmphasisPlan.deglowSpringMass == 1)
        #expect(AppleMusicLyrics.WordEmphasisPlan.deglowSpringStiffness == 14)
        #expect(AppleMusicLyrics.WordEmphasisPlan.deglowSpringDamping == 7)
    }

    @Test func synchronizedScheduleClampsTheSpringPeriodAndGlyphStagger() {
        let plan = AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 10,
            wordLength: 1,
            renderedGlyphCount: 1,
            timingGlyphCount: 1,
            languageIdentifier: "en",
            timingSource: .synchronized
        )

        #expect(plan.springPeriod == 3)
        #expect(plan.glyphStagger == 0.4)
        #expect(plan.riseDelays == [0.4])
        #expect(abs((plan.returnDelays.first ?? 0) - 20.4) < 0.000_001)
    }

    @Test func inferredTimingKeepsTheEstablishedPhraseFallback() {
        let plan = AppleMusicLyrics.WordEmphasisPlan.make(
            wordDuration: 2,
            wordLength: 1,
            renderedGlyphCount: 1,
            timingGlyphCount: 4,
            languageIdentifier: "zh-Hant",
            timingSource: .inferred
        )

        #expect(plan.factor == 1)
        #expect(plan.riseDelays == [0])
        #expect(plan.returnDelays == [1])
    }

    @Test func relativeLineAnchorPlacesTheFirstBaselineAtFortyPercent() {
        let visibleHeight: CGFloat = 800
        let firstBaselineOffset: CGFloat = 60
        let topInset = AppleMusicLyrics.LineTransitionPlan.selectedLineTopInset(
            visibleHeight: visibleHeight,
            firstBaselineOffset: firstBaselineOffset
        )

        #expect(abs(topInset + firstBaselineOffset - visibleHeight * 0.4) < 0.000_001)
    }

    @Test func blurPlanOnlyIncludesContextuallyVisibleNonselectedLines() {
        let plan = AppleMusicLyrics.LineBlurPlan.make(
            visibleLinePositions: [2, 3, 4],
            selectedLinePosition: 3
        )
        #expect(plan.blurredLinePositions == [2, 4])
        #expect(plan.radius == AppleMusicLyrics.LyricsSpecs.deselectedLineBlurRadius)

        let noSelectionPlan = AppleMusicLyrics.LineBlurPlan.make(
            visibleLinePositions: [2, 3, 4],
            selectedLinePosition: nil
        )
        #expect(noSelectionPlan.blurredLinePositions.isEmpty)
        #expect(noSelectionPlan.radius == 0)
    }

    @Test func structuredKaraokeUsesExplicitSyllableEnds() {
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(
                    characterRange: 0 ..< 3,
                    timeRange: 0 ..< 1,
                    syllables: [.init(characterRange: 0 ..< 3, timeRange: 0 ..< 1)]
                ),
                .init(
                    characterRange: 3 ..< 6,
                    timeRange: 1.5 ..< 3,
                    syllables: [.init(characterRange: 3 ..< 6, timeRange: 1.5 ..< 3)]
                ),
            ],
            duration: 3
        )

        let halfwayThroughFirstWord = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 0.5,
            lineDuration: 3,
            wordTimings: [],
            synchronizedTextTiming: timing,
            totalCharacterCount: 6,
            mode: .characterLevel
        )
        let betweenWords = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 1.25,
            lineDuration: 3,
            wordTimings: [],
            synchronizedTextTiming: timing,
            totalCharacterCount: 6,
            mode: .characterLevel
        )
        let halfwayThroughSecondWord = AppleMusicLyrics.KaraokeFill.fraction(
            elapsedTime: 2.25,
            lineDuration: 3,
            wordTimings: [],
            synchronizedTextTiming: timing,
            totalCharacterCount: 6,
            mode: .characterLevel
        )

        #expect(abs(halfwayThroughFirstWord - 0.25) < 0.000_001)
        #expect(abs(betweenWords - 0.5) < 0.000_001)
        #expect(abs(halfwayThroughSecondWord - 0.75) < 0.000_001)
    }
}

@MainActor
struct StructuredLineTextLayoutTests {
    @Test func exactWordsAndSyllablesOwnTheirGlyphs() throws {
        let content = "Hello"
        let attributedString = NSAttributedString(
            string: content,
            attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]
        )
        let timing = LyricsLine.Attachments.SynchronizedTextTiming(
            words: [
                .init(
                    characterRange: 0 ..< 5,
                    timeRange: 0 ..< 2,
                    syllables: [
                        .init(characterRange: 0 ..< 3, timeRange: 0 ..< 0.5),
                        .init(characterRange: 3 ..< 5, timeRange: 0.5 ..< 2),
                    ]
                ),
            ],
            duration: 2
        )

        let layout = try #require(AppleMusicLyrics.LineTextLayout.build(
            attributed: attributedString,
            content: content,
            wordTimings: [],
            synchronizedTextTiming: timing,
            languageIdentifier: "en-US",
            lineDuration: 2,
            textWidth: 400
        ))
        let word = try #require(layout.words.first)

        #expect(layout.words.count == 1)
        #expect(word.timingSource == .synchronized)
        #expect(word.characterRange == 0 ..< 5)
        #expect(word.syllables.count == 2)
        #expect(word.syllables.flatMap(\.glyphIndices).count == word.glyphs.count)
        #expect(word.emphasisDuration == 2)
        #expect(word.emphasisGlyphCount == word.glyphs.count)
        #expect(layout.languageIdentifier == "en-US")
    }
}
