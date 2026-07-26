import AppKit
import CoreText
import QuartzCore
import LyricsXFoundation

extension AppleMusicLyrics {
    /// One lyric line, rendered as a layer-backed `NSView`.
    ///
    /// The main text is a Core Animation layer tree — see
    /// `SyncedLyricsLineContentLayer` — built once per line and then driven
    /// entirely by scheduled animations. The view itself only draws the
    /// translation, measures, and decides *when* to hand the line its playback
    /// position; it never draws a glyph.
    ///
    /// This replaced a per-frame `draw(_:)` that solved Apple Music's emphasis
    /// spring on the CPU and composited the karaoke fill by hand. That could not
    /// be made to look right: Music scales each glyph *inside* a mask while the
    /// sung/un-sung gradient sweeps *outside* it, and a single drawing pass cannot
    /// separate the two. Everything visual now lives in the layer tree.
    final class SyncedLyricsLineView: NSView {
        // MARK: Model

        private(set) var line: LyricsLine?
        private(set) var originalIndex: Int = -1
        /// Position among the *enabled* lines (used for distance-based fading).
        var enabledPosition: Int = 0

        var onTap: ((LyricsLine) -> Void)?

        private var mainFontSize: CGFloat = 32
        private var translationFontSize: CGFloat = 18

        // MARK: State

        private(set) var isHighlighted = false
        private var karaokeFraction: CGFloat = 0
        private var blurRadius: CGFloat = 0

        // MARK: Cached layout

        private var mainAttributed: NSAttributedString?
        private var translationAttributed: NSAttributedString?
        private var mainTextSize: CGSize = .zero
        private var translationTextSize: CGSize = .zero
        private var textLayout: LineTextLayout?
        private var laidOutForWidth: CGFloat = -1

        // MARK: Layers

        private let contentLayer = SyncedLyricsLineContentLayer()

        // MARK: Layout constants

        private let verticalPadding: CGFloat = 28
        private let horizontalPadding: CGFloat = 24
        private let mainToTranslationSpacing: CGFloat = 4
        /// The active line's not-yet-sung text sits at 50% white
        /// (`selectedUpcomingTextColor`, from the live `LyricsSpecs` dump); the
        /// sung prefix fills to 100%. Other lines are told apart by the
        /// container's alpha, never by scale — Music's `deselectedTransform` is
        /// the identity.
        private let unsungOpacity: CGFloat = 0.5

        // MARK: Lifecycle

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            layer?.addSublayer(contentLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool {
            true
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            guard let scale = window?.backingScaleFactor else { return }
            contentLayer.contentsScale = scale
            laidOutForWidth = -1
            needsLayout = true
        }

        // MARK: Configuration

        func configure(line: LyricsLine, originalIndex: Int, enabledPosition: Int, mainFontSize: CGFloat, translationFontSize: CGFloat) {
            self.line = line
            self.originalIndex = originalIndex
            self.enabledPosition = enabledPosition
            self.mainFontSize = mainFontSize
            self.translationFontSize = translationFontSize
            rebuildAttributedStrings()
        }

        func updateFonts(mainFontSize: CGFloat, translationFontSize: CGFloat) {
            guard mainFontSize != self.mainFontSize || translationFontSize != self.translationFontSize else { return }
            self.mainFontSize = mainFontSize
            self.translationFontSize = translationFontSize
            rebuildAttributedStrings()
        }

        /// Re-reads the bilingual / Chinese-conversion preferences and rebuilds
        /// the attributed strings. Called when those preferences change while a
        /// track is already displayed.
        func refreshTranslation() {
            rebuildAttributedStrings()
        }

        private func rebuildAttributedStrings() {
            guard let line else {
                mainAttributed = nil
                translationAttributed = nil
                return
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byWordWrapping

            mainAttributed = NSAttributedString(
                string: line.content,
                attributes: [
                    .font: NSFont.systemFont(ofSize: mainFontSize, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph,
                ]
            )

            translationAttributed = Self.makeTranslationAttributedString(
                for: line,
                fontSize: translationFontSize,
                paragraph: paragraph
            )

            laidOutForWidth = -1
            needsLayout = true
            needsDisplay = true
        }

        private static func makeTranslationAttributedString(for line: LyricsLine, fontSize: CGFloat, paragraph: NSParagraphStyle) -> NSAttributedString? {
            guard AppleMusicLyrics.hostEnvironment.isBilingualPreferred(),
                  let translation = line.attachments.translation() else {
                return nil
            }
            let displayText = AppleMusicLyrics.hostEnvironment.transformTranslation(translation)
            return NSAttributedString(
                string: displayText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.7),
                    .paragraphStyle: paragraph,
                ]
            )
        }

        // MARK: Measurement & layout

        func preferredHeight(forWidth width: CGFloat) -> CGFloat {
            buildLayoutIfNeeded(forWidth: width)
            var height = verticalPadding * 2 + mainTextSize.height
            if translationAttributed != nil {
                height += mainToTranslationSpacing + translationTextSize.height
            }
            return ceil(height)
        }

        override func layout() {
            super.layout()
            buildLayoutIfNeeded(forWidth: bounds.width)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // The content layer's children are laid out y-down to match this
            // flipped view. AppKit already flips the backing layer of a flipped
            // view, so cancel that out rather than assuming either way.
            contentLayer.isGeometryFlipped = !(layer?.isGeometryFlipped ?? false)
            contentLayer.anchorPoint = .zero
            // The layer is bigger than the text it holds — see `textOutset` — so
            // back the origin off by that much to put the *text* on the padding.
            contentLayer.position = CGPoint(
                x: horizontalPadding - contentLayer.textOutset.width,
                y: verticalPadding - contentLayer.textOutset.height
            )
            CATransaction.commit()
        }

        /// Lay the main text out and rebuild the layer tree. Cached by width, and
        /// invalidated when the line, the fonts, or the backing scale change.
        private func buildLayoutIfNeeded(forWidth width: CGFloat) {
            guard width > 0, laidOutForWidth != width else { return }
            let textWidth = max(1, width - horizontalPadding * 2)

            guard let mainAttributed, let line else {
                textLayout = nil
                mainTextSize = .zero
                translationTextSize = .zero
                return
            }
            laidOutForWidth = width

            let layout = LineTextLayout.build(
                attributed: mainAttributed,
                content: line.content,
                wordTimings: line.wordTimingEntries ?? [],
                lineDuration: line.timetagDuration ?? 0,
                textWidth: textWidth
            )
            textLayout = layout
            mainTextSize = layout?.contentSize ?? .zero

            if let layout {
                // Only the active line reads as "half sung"; every other line is a
                // single flat colour, dimmed by the container's alpha instead.
                contentLayer.unsungColor = CGColor(gray: 1, alpha: isHighlighted ? unsungOpacity : 1)
                contentLayer.sungColor = CGColor(gray: 1, alpha: 1)
                contentLayer.rebuild(with: layout, contentsScale: window?.backingScaleFactor ?? 2)
                contentLayer.isHighlighted = isHighlighted
            }

            if let translationAttributed {
                let constraint = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
                let rect = translationAttributed.boundingRect(with: constraint, options: [.usesLineFragmentOrigin, .usesFontLeading])
                translationTextSize = CGSize(width: ceil(rect.width), height: ceil(rect.height))
            } else {
                translationTextSize = .zero
            }
            needsDisplay = true
        }

        // MARK: Drawing

        /// Only the translation is drawn — the main text is the layer tree.
        override func draw(_ dirtyRect: NSRect) {
            guard let translationAttributed else { return }
            let textWidth = max(1, bounds.width - horizontalPadding * 2)
            let translationY = verticalPadding + mainTextSize.height + mainToTranslationSpacing
            translationAttributed.draw(
                with: CGRect(x: horizontalPadding, y: translationY, width: textWidth, height: translationTextSize.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }

        // MARK: Highlight / Fade

        func setHighlighted(_ highlighted: Bool) {
            guard isHighlighted != highlighted else { return }
            isHighlighted = highlighted
            if !highlighted {
                karaokeFraction = 0
            }
            // Non-active lines read as one flat colour: no sweep, no emphasis.
            contentLayer.unsungColor = CGColor(gray: 1, alpha: highlighted ? unsungOpacity : 1)
            contentLayer.isHighlighted = highlighted
        }

        func animateAlpha(to target: CGFloat, duration: TimeInterval) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = target
            }
        }

        /// Apple Music's `deselectedTransform` is the identity — re-confirmed by
        /// the 2026-07-26 lldb dump — so this is deliberately a no-op scale. All
        /// of the active line's growth is per-glyph, never whole-line.
        func setLineSelected(_ selected: Bool, animated: Bool) {
            _ = selected
            _ = animated
        }

        // MARK: Blur

        /// Blur everything but the line being sung, the way Apple Music does.
        ///
        /// `SyncedLyricsLineLayer` carries a Gaussian blur filter for its whole
        /// life and only ever animates the radius — `sub_10019EBAC` writes
        /// `filters.gaussianBlur.inputRadius`, `sub_10019EEDC` drives it, and the
        /// selected line is exempted before any of that runs. This uses the same
        /// private `CAFilter` Music does (this app never ships through App
        /// Review), so the filter type, the key path, and the render-server-side
        /// evaluation are all Music's own — no `layerUsesCoreImageFilters`, no
        /// in-process Core Image pass.
        func setLineBlurred(_ blurred: Bool, animated: Bool) {
            let musicRadius = min(blurred ? LyricsSpecs.deselectedLineBlurRadius : 0, LyricsSpecs.maximumLineBlurRadius)
            let target = musicRadius * LyricsSpecs.renderedBlurRadiusScale
            guard target != blurRadius, let layer, installBlurFilterIfNeeded() else { return }
            let previous = blurRadius
            blurRadius = target

            if animated {
                let animation = CABasicAnimation(keyPath: Self.blurRadiusKeyPath)
                animation.fromValue = previous
                animation.toValue = target
                animation.duration = LyricsSpecs.lineBlurAnimationDuration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: Self.blurRadiusKeyPath)
            } else {
                layer.removeAnimation(forKey: Self.blurRadiusKeyPath)
            }
            layer.setValue(target, forKeyPath: Self.blurRadiusKeyPath)
        }

        /// The filter's `name` is what makes the key path above resolve, so the
        /// two have to agree — hence one constant rather than two literals. With
        /// the name matching the type, the key path is byte-for-byte the one in
        /// Music's disassembly.
        private static let blurFilterName = "gaussianBlur"
        private static let blurRadiusKeyPath = "filters.\(blurFilterName).inputRadius"

        private func installBlurFilterIfNeeded() -> Bool {
            guard let layer else { return false }
            guard layer.filters == nil else { return true }
            guard let filter = Self.makePrivateGaussianBlurFilter() else { return false }
            layer.filters = [filter]
            return true
        }

        /// `CAFilter` is private API, reached through the runtime so there is
        /// nothing to link against. If a future macOS removes it this returns
        /// nil and the panel simply loses its depth blur — nothing else breaks.
        private static func makePrivateGaussianBlurFilter() -> NSObject? {
            guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
                  let filter = filterClass
                  .perform(NSSelectorFromString("filterWithType:"), with: blurFilterName)?
                  .takeUnretainedValue() as? NSObject
            else { return nil }
            filter.setValue(blurFilterName, forKey: "name")
            filter.setValue(0.0, forKey: "inputRadius")
            return filter
        }

        // MARK: Karaoke (per-frame, highlighted line only)

        func updateKaraoke(elapsedTime: TimeInterval, lineDuration: TimeInterval, mode: KaraokeMode) {
            guard let line, isHighlighted else { return }
            buildLayoutIfNeeded(forWidth: bounds.width)

            karaokeFraction = KaraokeFill.fraction(
                elapsedTime: elapsedTime,
                lineDuration: lineDuration,
                wordTimings: line.wordTimingEntries ?? [],
                totalCharacterCount: line.content.count,
                mode: mode
            )
            contentLayer.update(elapsedTime: elapsedTime, fillFraction: karaokeFraction)
        }

        // MARK: Hit testing

        override func mouseDown(with event: NSEvent) {
            // Swallow so `mouseUp` is delivered to this view.
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), let line else { return }
            onTap?(line)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    /// The "•••" instrumental indicator shown during a long intro (and, later,
    /// interludes), mirroring Apple Music. Three dots light up left-to-right and
    /// swell slightly as the gap nears its end. Drawn as plain circles, so it is
    /// orientation-agnostic (no flipped-layer concerns).
    final class SyncedLyricsInstrumentalView: NSView {
        private var progress: CGFloat = 0
        private var lastDrawnProgress: CGFloat = -1

        private let horizontalPadding: CGFloat = 24
        private let dotRadius: CGFloat = 7
        private let dotSpacing: CGFloat = 26
        private let dotCount = 3

        var preferredHeight: CGFloat {
            72
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool {
            true
        }

        func setProgress(_ value: CGFloat) {
            let clamped = min(1, max(0, value))
            progress = clamped
            if abs(clamped - lastDrawnProgress) >= 0.01 {
                needsDisplay = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            lastDrawnProgress = progress
            guard let context = NSGraphicsContext.current?.cgContext else { return }

            // Anticipation swell over the last 15% of the gap.
            let anticipation = 1 + 0.18 * max(0, (progress - 0.85) / 0.15)
            let centerY = bounds.midY

            for dotIndex in 0 ..< dotCount {
                let segmentStart = CGFloat(dotIndex) / CGFloat(dotCount)
                let local = min(1, max(0, (progress - segmentStart) * CGFloat(dotCount)))
                let alpha = 0.25 + 0.75 * local
                let radius = dotRadius * (0.8 + 0.2 * local) * anticipation
                let centerX = horizontalPadding + dotRadius + CGFloat(dotIndex) * dotSpacing
                context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
                context.fillEllipse(in: CGRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2))
            }
        }
    }
}
