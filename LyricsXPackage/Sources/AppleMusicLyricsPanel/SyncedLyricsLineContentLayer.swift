import AppKit
import QuartzCore

extension AppleMusicLyrics {
    /// One lyric line's main text, built the way Apple Music builds it.
    ///
    /// ```
    /// SyncedLyricsLineContentLayer          mask = glyphMaskContainer
    /// ├── backgroundColorLayer              the un-sung colour, over the whole line
    /// ├── LineProgressGradientLayer × rows  the sung colour + its feathered edge
    /// └── glyphMaskContainer                (the mask)
    ///     └── word colour layer × words     mask = word layer
    ///         └── word layer                carries the glow; holds the glyphs
    ///             └── GlyphRunLayer × glyphs
    /// ```
    ///
    /// Colour and sweep live *outside* the mask; glyph geometry lives *inside* it.
    /// That is the whole trick: a glyph can scale and lift while the sung/un-sung
    /// boundary sweeping across it stays a continuous ramp, because the two are
    /// composited rather than drawn together. Reproducing this with a per-frame
    /// `draw(_:)` is not possible — which is why the previous CPU implementation
    /// never looked right no matter how the constants were tuned.
    ///
    /// Built from `sub_100169AC8` (the line), `sub_10018C12C` (the word) and
    /// `sub_10018B2B4` (the emphasis schedule).
    final class SyncedLyricsLineContentLayer: CALayer {
        /// A word, plus the layers standing in for it.
        private final class WordNode {
            let word: LineTextLayout.Word
            let colorLayer: NoAnimationLayer
            let wordLayer: NoAnimationLayer
            let glyphLayers: [GlyphRunLayer]
            /// How far the glyph layers sit inside the padded word box. Glyph
            /// geometry is computed in the word's *text* box — the way Music
            /// computes it — and then shifted by this to land in the padded one.
            let glyphOffset: CGPoint
            /// Set once the word's emphasis batch has been scheduled, so a display
            /// link running at 120Hz does not re-schedule it 120 times a second.
            var isEmphasisScheduled = false
            /// The pending "travel back to rest" batch, kept so it can be cancelled
            /// if the line is recycled mid-word.
            var pendingReturn: DispatchWorkItem?

            init(
                word: LineTextLayout.Word,
                colorLayer: NoAnimationLayer,
                wordLayer: NoAnimationLayer,
                glyphLayers: [GlyphRunLayer],
                glyphOffset: CGPoint
            ) {
                self.word = word
                self.colorLayer = colorLayer
                self.wordLayer = wordLayer
                self.glyphLayers = glyphLayers
                self.glyphOffset = glyphOffset
            }

            /// Where glyph `index` sits when nothing is emphasizing it.
            func restingOrigin(ofGlyphAt index: Int) -> CGPoint {
                let origin = word.glyphs[index].frame.origin
                return CGPoint(x: origin.x + glyphOffset.x, y: origin.y + glyphOffset.y)
            }
        }

        // MARK: Appearance

        /// Colour of text that has not been sung yet.
        var unsungColor: CGColor = .init(gray: 1, alpha: 0.5) {
            didSet { backgroundColorLayer.backgroundColor = unsungColor }
        }

        /// Colour of text that has been sung. Only visible while `isHighlighted`.
        var sungColor: CGColor = .init(gray: 1, alpha: 1) {
            didSet { progressGradientLayers.forEach { $0.color = sungColor } }
        }

        /// While false the sweep is hidden entirely and the line reads as one flat
        /// colour, which is what every line other than the active one looks like.
        var isHighlighted = false {
            didSet {
                guard isHighlighted != oldValue else { return }
                progressGradientLayers.forEach { $0.isHidden = !isHighlighted }
                if !isHighlighted { resetEmphasis() }
            }
        }

        /// Interpolation factor for `emphasizingScaleRange` and `glowRange`.
        ///
        /// Music stores this per word and we have not yet recovered where it comes
        /// from, so this is the full-emphasis default. Everything else about the
        /// schedule is Music's; only the amplitude is assumed.
        var emphasisFactor: CGFloat = 1

        // MARK: Layers

        private let backgroundColorLayer = NoAnimationLayer()
        private let glyphMaskContainer = NoAnimationLayer()
        private var progressGradientLayers: [LineProgressGradientLayer] = []
        private var wordNodes: [WordNode] = []
        private var layout: LineTextLayout?
        /// Cumulative text width before each visual row, so the sweep cascades row
        /// by row instead of lighting every wrapped row at once.
        private var cumulativeWidthBeforeRow: [CGFloat] = []
        /// How far this layer extends past the text block on every side.
        ///
        /// This layer's own mask is the glyph tree, and a mask is confined to the
        /// bounds of the layer it masks — so without room here, everything emphasis
        /// adds (the lift, the swell, the glow) is cut off flush with the edge of
        /// the text. Whoever positions this layer has to subtract it, or the text
        /// lands `textOutset` away from where it was measured to go.
        private(set) var textOutset: CGSize = .zero

        override init() {
            super.init()
            isGeometryFlipped = true
            addSublayer(backgroundColorLayer)
            mask = glyphMaskContainer
            backgroundColorLayer.backgroundColor = unsungColor
        }

        override init(layer: Any) {
            super.init(layer: layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func action(forKey event: String) -> CAAction? {
            nil
        }

        // MARK: Building

        /// Tear the tree down and build it again for `layout`. Called when the
        /// line, the font, or the available width changes — never per frame.
        func rebuild(with layout: LineTextLayout, contentsScale: CGFloat) {
            resetEmphasis()
            self.layout = layout

            wordNodes.forEach { $0.colorLayer.removeFromSuperlayer() }
            progressGradientLayers.forEach { $0.removeFromSuperlayer() }
            wordNodes = []
            progressGradientLayers = []

            let rowCount = max(1, layout.visualLineWidths.count)
            let rowHeight = layout.contentSize.height / CGFloat(rowCount)
            let widestWord = layout.words.map(\.frame.width).max() ?? 0
            let headroom = Self.emphasisHeadroom(forWordSize: CGSize(width: widestWord, height: rowHeight))
            textOutset = CGSize(width: ceil(headroom.width), height: ceil(headroom.height))

            bounds = CGRect(origin: .zero, size: CGSize(
                width: layout.contentSize.width + textOutset.width * 2,
                height: layout.contentSize.height + textOutset.height * 2
            ))
            backgroundColorLayer.frame = bounds
            glyphMaskContainer.frame = bounds

            var runningWidth: CGFloat = 0
            cumulativeWidthBeforeRow = layout.visualLineWidths.map { width in
                defer { runningWidth += width }
                return runningWidth
            }

            for word in layout.words {
                wordNodes.append(makeWordNode(for: word, contentsScale: contentsScale))
            }
            buildProgressGradients(for: layout)
        }

        private func makeWordNode(for word: LineTextLayout.Word, contentsScale: CGFloat) -> WordNode {
            // Glyph geometry is computed in the word's own text box, the way Music
            // computes it, then shifted into a box with room to swell and into this
            // layer's outset.
            let headroom = Self.emphasisHeadroom(forWordSize: word.frame.size)
            let paddedFrame = word.frame
                .insetBy(dx: -headroom.width, dy: -headroom.height)
                .offsetBy(dx: textOutset.width, dy: textOutset.height)
            let glyphOffset = CGPoint(x: headroom.width, y: headroom.height)

            let wordLayer = NoAnimationLayer()
            wordLayer.frame = CGRect(origin: .zero, size: paddedFrame.size)
            wordLayer.contentsScale = contentsScale

            var glyphLayers: [GlyphRunLayer] = []
            for glyph in word.glyphs {
                let glyphLayer = GlyphRunLayer(
                    run: glyph.run,
                    glyphRange: glyph.glyphRange,
                    textPosition: glyph.textPosition,
                    contentsScale: contentsScale
                )
                glyphLayer.frame = glyph.frame.offsetBy(dx: glyphOffset.x, dy: glyphOffset.y)
                // Music hangs the glow on the *word* layer, which works there only
                // because it also rasterizes it — a layer that has sublayers but no
                // content of its own casts a shadow shaped like its bounds, which
                // inside a mask shows up as a bright rectangle behind the word. The
                // glyph layers have real drawn content, so their shadow follows the
                // letter outline with no rasterization and no artefact.
                glyphLayer.shadowColor = CGColor(gray: 1, alpha: 1)
                glyphLayer.shadowRadius = LyricsSpecs.glowRadius
                glyphLayer.shadowOpacity = LyricsSpecs.glowOpacityRange.lowerBound
                glyphLayer.shadowOffset = .zero
                wordLayer.addSublayer(glyphLayer)
                glyphLayers.append(glyphLayer)
            }

            // Inside a mask only alpha counts, so this is opaque white: the word's
            // brightness comes from the colour layers underneath the mask, not
            // from here. Music uses this layer for its word-level colour crossfade,
            // which the per-character sweep makes unnecessary for us.
            let colorLayer = NoAnimationLayer()
            colorLayer.frame = paddedFrame
            colorLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
            colorLayer.mask = wordLayer
            glyphMaskContainer.addSublayer(colorLayer)

            return WordNode(
                word: word,
                colorLayer: colorLayer,
                wordLayer: wordLayer,
                glyphLayers: glyphLayers,
                glyphOffset: glyphOffset
            )
        }

        /// Room an emphasized word needs beyond its own text box, on each side:
        /// half the swell (the glyph grows about its centre), the lift, and enough
        /// for the glow's blur. A mask cannot paint outside the layer it masks, so
        /// both the word's colour layer and this whole layer have to reserve it —
        /// otherwise emphasis is silently cut back to the text box.
        private static func emphasisHeadroom(forWordSize size: CGSize) -> CGSize {
            let swell = LyricsSpecs.emphasizingScaleRange.upperBound - 1
            return CGSize(
                width: size.width * swell * 0.5 + LyricsSpecs.glowRadius * 2,
                height: size.height * swell * 0.5 + LyricsSpecs.syllableLift + LyricsSpecs.glowRadius * 2
            )
        }

        private func buildProgressGradients(for layout: LineTextLayout) {
            // A gradient per visual row: each row sweeps on its own, so a wrapped
            // line lights up row after row rather than all at once.
            let rowHeight = layout.visualLineWidths.isEmpty
                ? layout.contentSize.height
                : layout.contentSize.height / CGFloat(layout.visualLineWidths.count)
            for (rowIndex, rowWidth) in layout.visualLineWidths.enumerated() {
                let gradient = LineProgressGradientLayer(
                    lineWidth: rowWidth,
                    lineHeight: rowHeight,
                    verticalPadding: LyricsSpecs.syllableLift + LyricsSpecs.glowRadius,
                    color: sungColor
                )
                gradient.isHidden = !isHighlighted
                gradient.position = CGPoint(
                    x: textOutset.width + layout.visualLineLeftEdges[rowIndex] + gradient.originX(forFillEdge: 0),
                    y: textOutset.height + CGFloat(rowIndex) * rowHeight - gradient.verticalPadding
                )
                insertSublayer(gradient, above: backgroundColorLayer)
                progressGradientLayers.append(gradient)
            }
        }

        // MARK: Per-frame update

        /// Advance the sweep and schedule any word whose turn has come.
        ///
        /// `elapsedTime` is seconds since the line started. Nothing here animates
        /// glyphs directly: it only decides *when* to hand a word to
        /// `LayerPropertyAnimator`, which is what keeps the per-frame cost to a few
        /// comparisons even at 120Hz.
        func update(elapsedTime: TimeInterval, fillFraction: CGFloat) {
            guard let layout, isHighlighted else { return }
            updateSweep(layout: layout, fillFraction: fillFraction)
            scheduleDueWords(elapsedTime: elapsedTime)
        }

        private func updateSweep(layout: LineTextLayout, fillFraction: CGFloat) {
            let totalWidth = max(0.0001, layout.totalTextWidth)
            let filledWidth = totalWidth * min(1, max(0, fillFraction))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (rowIndex, gradient) in progressGradientLayers.enumerated() {
                let rowWidth = layout.visualLineWidths[rowIndex]
                let filledInRow = min(max(0, filledWidth - cumulativeWidthBeforeRow[rowIndex]), rowWidth)
                let originX = filledInRow >= rowWidth
                    ? gradient.originXForCompletelyFilled()
                    : gradient.originX(forFillEdge: filledInRow)
                gradient.position.x = textOutset.width + layout.visualLineLeftEdges[rowIndex] + originX
            }
            CATransaction.commit()
        }

        private func scheduleDueWords(elapsedTime: TimeInterval) {
            // Music starts a word's animation `animationHeadstart` before its own
            // timing, otherwise the swell reads as half a beat late.
            let cursor = elapsedTime + LyricsSpecs.animationHeadstart
            for node in wordNodes where !node.isEmphasisScheduled {
                guard let timeRange = node.word.timeRange, cursor >= timeRange.lowerBound else { continue }
                node.isEmphasisScheduled = true
                emphasize(node)
            }
        }

        // MARK: Emphasis

        /// Schedule one word's ripple: every glyph springs up to the emphasized
        /// size, staggered against its neighbours, then travels back.
        private func emphasize(_ node: WordNode) {
            let glyphCount = node.glyphLayers.count
            guard glyphCount > 0 else { return }
            // The spring and the return both scale with the *phrase*, not with
            // this one word — see `LineTextLayout.Word.phraseDuration`. With
            // per-character time tags a word is a single glyph, and word-scaled
            // timings make it rise, freeze at the top for about 0.6 s and drop,
            // one character at a time. Phrase-scaled timings bring the return
            // forward to well inside the spring's settling time, so a character
            // is still on its way up when it starts back down and its motion
            // overlaps its neighbours'.
            let duration = node.word.phraseDuration > 0 ? node.word.phraseDuration : node.word.duration
            let spring = SpringTimingParameters(
                dampingRatio: LyricsSpecs.emphasisDampingRatio,
                period: LyricsSpecs.emphasisSpringPeriod(wordDuration: duration)
            )
            let stagger = LyricsSpecs.glyphStagger(wordDuration: duration, glyphCount: node.word.phraseGlyphCount)
            let scale = LyricsSpecs.emphasizingScaleRange.lowerBound
                + emphasisFactor * (LyricsSpecs.emphasizingScaleRange.upperBound - LyricsSpecs.emphasizingScaleRange.lowerBound)

            let glow = LyricsSpecs.glowOpacityRange.lowerBound
                + Float(emphasisFactor) * (LyricsSpecs.glowOpacityRange.upperBound - LyricsSpecs.glowOpacityRange.lowerBound)

            for (glyphIndex, glyphLayer) in node.glyphLayers.enumerated() {
                let target = emphasizedOrigin(ofGlyphAt: glyphIndex, in: node, scale: scale)
                let animator = LayerPropertyAnimator(layers: [glyphLayer], timing: spring)
                animator.addChange {
                    Self.place(glyphLayer, atRestingOrigin: target)
                    glyphLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                    glyphLayer.shadowOpacity = glow
                }
                // Music offsets by `index + 1`, which costs a whole stagger before
                // its first glyph moves. It can afford that because its stagger is
                // a word's duration split across that word's glyphs. Ours would be
                // a phrase's stagger applied to a word holding one glyph — every
                // character would start moving a beat after it was sung. The
                // ripple inside a word is unchanged; only the leading offset goes.
                animator.run(afterDelay: stagger * Double(glyphIndex))
            }

            scheduleReturn(
                for: node,
                spring: spring,
                stagger: stagger,
                glyphCount: node.word.phraseGlyphCount,
                duration: duration
            )
        }

        /// Apple Music's emphasized position for one glyph.
        ///
        /// `sub_10018B2B4` moves the glyph to
        /// `x = (originX + W(1-s)/2 + s·originX) / 2`, which expands to
        /// "scale the *word* about its centre by `(1 + s) / 2`". So the word
        /// spreads at half the rate each glyph grows, and neighbouring glyphs
        /// crowd slightly — that squeeze is the look, not a bug to compensate for.
        private func emphasizedOrigin(
            ofGlyphAt glyphIndex: Int,
            in node: WordNode,
            scale: CGFloat
        ) -> CGPoint {
            let origin = node.word.glyphs[glyphIndex].frame.origin
            let size = node.word.frame.size
            let horizontalSlack = (size.width - scale * size.width) * 0.5
            let verticalSlack = size.height - scale * size.height
            return CGPoint(
                x: (origin.x + horizontalSlack + scale * origin.x) * 0.5 + node.glyphOffset.x,
                // Music's own y is `(originY + verticalSlack + s·originY) * 0.25 -
                // syllableLift`, which for its layout (glyphs sit at the word's
                // top, so originY is 0) is the same as this. Anchoring on the
                // laid-out origin instead means a word that has finished returns
                // exactly where it started rather than three points high.
                y: origin.y + node.glyphOffset.y + verticalSlack * 0.25 - LyricsSpecs.syllableLift
            )
        }

        /// Move `layer` so that its *untransformed* frame origin lands on `origin`.
        ///
        /// Assigning `frame` would be wrong here: Core Animation derives `position`
        /// from the frame as the transform leaves it, so a glyph that is mid-swell
        /// creeps a few points every time it is repositioned, and the drift never
        /// washes out.
        private static func place(_ layer: CALayer, atRestingOrigin origin: CGPoint) {
            layer.position = CGPoint(
                x: origin.x + layer.bounds.width * layer.anchorPoint.x,
                y: origin.y + layer.bounds.height * layer.anchorPoint.y
            )
        }

        /// The return pass runs `2 · wordDuration / glyphCount` after each glyph's
        /// own start, exactly as Music schedules it.
        ///
        /// It has to be a real timer rather than a second animation queued up front:
        /// two `beginTime`-delayed animations on the same key path would have the
        /// later one's backwards fill override the earlier one for its whole run,
        /// pinning the glyph at rest instead of letting it swell.
        private func scheduleReturn(
            for node: WordNode,
            spring: SpringTimingParameters,
            stagger: TimeInterval,
            glyphCount: Int,
            duration: TimeInterval
        ) {
            let returnDelay = LyricsSpecs.returnDelay(wordDuration: duration, glyphCount: glyphCount)
            let work = DispatchWorkItem { [weak node] in
                guard let node else { return }
                for (glyphIndex, glyphLayer) in node.glyphLayers.enumerated() {
                    let rest = node.restingOrigin(ofGlyphAt: glyphIndex)
                    let animator = LayerPropertyAnimator(layers: [glyphLayer], timing: spring)
                    animator.addChange {
                        Self.place(glyphLayer, atRestingOrigin: rest)
                        glyphLayer.setAffineTransform(.identity)
                        glyphLayer.shadowOpacity = LyricsSpecs.glowOpacityRange.lowerBound
                    }
                    animator.run(afterDelay: stagger * Double(glyphIndex))
                }
            }
            node.pendingReturn?.cancel()
            node.pendingReturn = work
            DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay, execute: work)
        }

        /// Put every glyph back at rest immediately, cancelling anything pending.
        /// Called when the line stops being the active one, or is recycled for a
        /// different lyric.
        func resetEmphasis() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for node in wordNodes {
                node.pendingReturn?.cancel()
                node.pendingReturn = nil
                node.isEmphasisScheduled = false
                for (glyphIndex, glyphLayer) in node.glyphLayers.enumerated() {
                    glyphLayer.removeAllAnimations()
                    Self.place(glyphLayer, atRestingOrigin: node.restingOrigin(ofGlyphAt: glyphIndex))
                    glyphLayer.setAffineTransform(.identity)
                    glyphLayer.shadowOpacity = LyricsSpecs.glowOpacityRange.lowerBound
                }
            }
            for (rowIndex, gradient) in progressGradientLayers.enumerated() {
                let leftEdge = layout?.visualLineLeftEdges[rowIndex] ?? 0
                gradient.position.x = textOutset.width + leftEdge + gradient.originX(forFillEdge: 0)
            }
            CATransaction.commit()
        }
    }
}
