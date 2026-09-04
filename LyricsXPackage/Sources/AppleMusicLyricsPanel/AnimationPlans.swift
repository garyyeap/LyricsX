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
            timingSource: TimingSource,
            structuredEmphasisPolicy: StructuredEmphasisPolicy = .appleMusic26
        ) -> WordEmphasisPlan {
            let safeDuration = max(0, wordDuration)
            let safeRenderedGlyphCount = max(0, renderedGlyphCount)
            let safeTimingGlyphCount = max(1, timingGlyphCount)
            let factor: CGFloat
            // Music offsets every glyph by `index + 1`, which costs a whole
            // stagger before its first glyph moves. The full-emphasis look and
            // the inline-tag fallback drop that leading offset.
            let leadsWithAStagger: Bool
            switch (timingSource, structuredEmphasisPolicy) {
            case (.synchronized, .appleMusic26):
                if LyricsLanguageCapabilities.allowsAdditionalEmphasis(languageIdentifier: languageIdentifier),
                   safeDuration > 1,
                   wordLength <= 7 {
                    factor = CGFloat(min(safeDuration, 2) - 1)
                } else {
                    factor = 0
                }
                leadsWithAStagger = true
            case (.synchronized, .fullEmphasis),
                 (.inferred, _):
                factor = 1
                leadsWithAStagger = false
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
                glyphStagger * TimeInterval(glyphIndex + (leadsWithAStagger ? 1 : 0))
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
        /// `LyricsSpecs.lineChangeSpringTimingParametersValues` as Music 26.6's
        /// `LyricsSpecs` initializer (`sub_1001D1C28`) fills it in; neither the
        /// pretty-mode closure nor Music's own overrides touch it. Every visible
        /// row rides this spring during an Apple Music line change: damping
        /// ratio ≈ 0.9, natural period ≈ 0.63 s.
        static let normalSpringMass: CGFloat = 1
        static let normalSpringStiffness: CGFloat = 100
        static let normalSpringDamping: CGFloat = 18
        /// `LyricsSpecs.lineDelay` in the full-window (pretty) mode; the sidebar
        /// uses 0.02. `sub_1001DCBD4` delays row `n` by `lineDelay × n` counted
        /// from the top of the viewport.
        static let appleMusicLineDelay: TimeInterval = 0.05
        /// When the lyrics move backwards the same function hands the delays out
        /// from the bottom row up and halves them — its own debug log calls this
        /// "the duration hack".
        static let appleMusicBackwardLineDelayScale: Double = 0.5
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
