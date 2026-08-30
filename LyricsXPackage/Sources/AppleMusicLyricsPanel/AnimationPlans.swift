import AppKit

extension AppleMusicLyrics {
    struct WordEmphasisPlan: Equatable {
        enum TimingSource: Equatable {
            case synchronized
            case inferred
        }

        let factor: CGFloat
        let scale: CGFloat
        let glowOpacity: Float
        let springPeriod: TimeInterval
        let glyphStagger: TimeInterval
        let riseDelays: [TimeInterval]
        let returnDelays: [TimeInterval]
        let deglowDelay: TimeInterval

        static let deglowSpringMass: CGFloat = 1
        static let deglowSpringStiffness: CGFloat = 14
        static let deglowSpringDamping: CGFloat = 7

        static func make(
            wordDuration: TimeInterval,
            wordLength: Int,
            renderedGlyphCount: Int,
            timingGlyphCount: Int,
            languageIdentifier: String?,
            timingSource: TimingSource
        ) -> WordEmphasisPlan {
            let safeDuration = max(0, wordDuration)
            let safeRenderedGlyphCount = max(0, renderedGlyphCount)
            let safeTimingGlyphCount = max(1, timingGlyphCount)
            let factor: CGFloat
            switch timingSource {
            case .synchronized:
                if LyricsLanguageCapabilities.allowsAdditionalEmphasis(languageIdentifier: languageIdentifier),
                   safeDuration > 1,
                   wordLength <= 7 {
                    factor = CGFloat(min(safeDuration, 2) - 1)
                } else {
                    factor = 0
                }
            case .inferred:
                factor = 1
            }

            let scale = LyricsSpecs.emphasizingScaleRange.lowerBound
                + factor * (LyricsSpecs.emphasizingScaleRange.upperBound - LyricsSpecs.emphasizingScaleRange.lowerBound)
            let glowOpacity = LyricsSpecs.glowOpacityRange.lowerBound
                + Float(factor) * (LyricsSpecs.glowOpacityRange.upperBound - LyricsSpecs.glowOpacityRange.lowerBound)
            let glyphStagger = LyricsSpecs.glyphStagger(
                wordDuration: safeDuration,
                glyphCount: safeTimingGlyphCount
            )
            let returnInterval = LyricsSpecs.returnDelay(
                wordDuration: safeDuration,
                glyphCount: safeTimingGlyphCount
            )
            let riseDelays = (0 ..< safeRenderedGlyphCount).map { glyphIndex in
                switch timingSource {
                case .synchronized:
                    return glyphStagger * TimeInterval(glyphIndex + 1)
                case .inferred:
                    return glyphStagger * TimeInterval(glyphIndex)
                }
            }
            let returnDelays = riseDelays.map { $0 + returnInterval }

            return WordEmphasisPlan(
                factor: factor,
                scale: scale,
                glowOpacity: glowOpacity,
                springPeriod: LyricsSpecs.emphasisSpringPeriod(wordDuration: safeDuration),
                glyphStagger: glyphStagger,
                riseDelays: riseDelays,
                returnDelays: returnDelays,
                deglowDelay: safeDuration
            )
        }
    }

    enum LyricsLanguageCapabilities {
        private static let languagesWithoutAdditionalEmphasis: Set<String> = ["ar", "he", "zh", "ja"]

        static func allowsAdditionalEmphasis(languageIdentifier: String?) -> Bool {
            guard let languageIdentifier, !languageIdentifier.isEmpty else { return true }
            let baseLanguage = languageIdentifier
                .lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map(String.init) ?? languageIdentifier.lowercased()
            return !languagesWithoutAdditionalEmphasis.contains(baseLanguage)
        }
    }

    enum LineTransitionPlan {
        static let selectedLineBaselineViewportFraction: CGFloat = 0.4
        static let normalSpringMass: CGFloat = 1
        static let normalSpringStiffness: CGFloat = 100
        static let normalSpringDamping: CGFloat = 18
        static let interactiveSpringMass: CGFloat = 2
        static let interactiveSpringStiffness: CGFloat = 260
        static let interactiveSpringDamping: CGFloat = 50
        static let cascadeSpringPeriod: TimeInterval = 0.6
        static let cascadeSpringDampingRatio: CGFloat = 0.725
        static let cascadeSettleDuration: TimeInterval = 0.5
        static let cascadeStagger: TimeInterval = 0.08
        static let cascadeAboveLineCount = 3
        static let cascadeBelowLineCount = 6
        static let rapidTransitionThreshold: TimeInterval = 0.4
        static let rapidSettleSpringPeriod: TimeInterval = 0.5
        static let rapidSettleDampingRatio: CGFloat = 1

        /// Apple Music's `.topRelative` value positions the text baseline at a
        /// percentage of the visible card height. Our row frame also includes its
        /// own top padding, so subtract the complete baseline offset rather than
        /// only the font ascent recovered from Music's text-only line frame.
        static func selectedLineTopInset(
            visibleHeight: CGFloat,
            firstBaselineOffset: CGFloat
        ) -> CGFloat {
            max(0, visibleHeight * selectedLineBaselineViewportFraction - firstBaselineOffset)
        }
    }

    struct LineBlurPlan: Equatable {
        let blurredLinePositions: Set<Int>
        let radius: CGFloat

        static func make(visibleLinePositions: Set<Int>, selectedLinePosition: Int?) -> LineBlurPlan {
            guard let selectedLinePosition else {
                return LineBlurPlan(blurredLinePositions: [], radius: 0)
            }
            return LineBlurPlan(
                blurredLinePositions: visibleLinePositions.subtracting([selectedLinePosition]),
                radius: LyricsSpecs.deselectedLineBlurRadius
            )
        }
    }
}
