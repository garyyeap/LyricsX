import AppKit
import QuartzCore
import Combine
import LyricsXFoundation
import MSDisplayLink

// MARK: - Container View (AppKit + CALayer lyrics engine)

extension AppleMusicLyrics {
    final class SyncedLyricsContainerView: NSView {
        // MARK: Inputs

        var onSeek: ((TimeInterval) -> Void)?
        weak var interactionState: InteractionStateModel?
        var karaokeMode: KaraokeMode = .characterLevel

        // MARK: Subviews

        private let scrollView = NSScrollView()
        private let documentView = FlippedDocumentView()
        private let viewportMaskLayer = CAGradientLayer()

        // MARK: State

        private var lyrics: Lyrics?
        private var enabledLineViews: [SyncedLyricsLineView] = []
        private var lineViewByOriginalIndex: [Int: SyncedLyricsLineView] = [:]
        private var enabledOriginalIndices: [Int] = []
        private var highlightedOriginalIndex: Int?
        private var wasFollowing = true
        private var mainFontSize: CGFloat = 32
        private var translationFontSize: CGFloat = 18
        private var signature: LayoutSignature?
        private var lastLaidOutSize: CGSize = .zero
        private var displayLink: DisplayLink?
        private var preferenceObservers: Set<AnyCancellable> = []
        private let lineTransitionCoordinator = LineTransitionCoordinator()
        private var pendingInteractiveTargetOriginalIndex: Int?
        private var lastLineTransitionTime: CFTimeInterval?
        private var lineTransitionTimeProvider: () -> CFTimeInterval = CACurrentMediaTime
        /// Apple Music ends the upper fade 70 points into its flipped lyrics
        /// container and starts the lower fade halfway through the viewport. This
        /// container is not flipped, so the gradient vector is reversed below while
        /// retaining Apple's recovered stop locations.
        private let viewportTopEdgeFadeDistance: CGFloat = 70
        private let viewportBottomFadeStartLocation: CGFloat = 0.5
        /// The lyrics display time resolved once per display-link frame; drives the
        /// karaoke fill and the intro/interlude indicators together.
        private var resolvedPlaybackTime: TimeInterval = 0

        /// Normal advances use the previous SwiftUI row cascade because one
        /// highly damped clip spring makes the stack look like a rigid translation.
        /// Rapid advances settle the clip as a unit so delayed row springs cannot
        /// pile up when several highlights arrive together.
        private var lastHighlightedPosition: Int?
        /// A line advance further than this (e.g. a seek) snaps instantly instead of
        /// springing across the whole song.
        private let scrollJumpThreshold = 5
        // The active main-vocal baseline uses Apple Music's `.topRelative(40)` anchor.

        // Intro "•••" instrumental indicator. Additive: nil unless the first
        // vocal line starts after `introGapThreshold`, in which case the engine
        // behaves exactly as without it.
        private var instrumentalView: SyncedLyricsInstrumentalView?
        private var introEndTime: Double = 0
        private let introGapThreshold: Double = 4.0

        /// Mid-song instrumental breaks (word-timed lyrics only, where line end
        /// times are known). Persistent inter-verse slots that fill during their
        /// gap. Additive: empty unless a real gap is detected.
        private struct InterludeSegment {
            let view: SyncedLyricsInstrumentalView
            let startTime: Double
            let endTime: Double
            let afterEnabledPosition: Int
        }

        private var interludeSegments: [InterludeSegment] = []
        private let interludeGapThreshold: Double = 5.0

        // MARK: Lifecycle

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            configureViewportMask()
            setupScrollView()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userWillScroll),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            // Re-render translations live when the host's translation
            // preferences change while a track is displayed.
            AppleMusicLyrics.hostEnvironment.translationSettingsDidChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refreshTranslations() }
                .store(in: &preferenceObservers)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            displayLink = nil
        }

        func setLineTransitionTimeProvider(_ provider: @escaping () -> CFTimeInterval) {
            lineTransitionTimeProvider = provider
        }

        private func setupScrollView() {
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.contentView.drawsBackground = false
            // Every line and instrumental-focus transition attaches its spring to
            // this layer, so create it before the first highlight update.
            scrollView.contentView.wantsLayer = true
            scrollView.documentView = documentView
            scrollView.frame = bounds
            addSubview(scrollView)
        }

        private func configureViewportMask() {
            viewportMaskLayer.colors = [
                CGColor(gray: 1, alpha: 0),
                CGColor(gray: 1, alpha: 1),
                CGColor(gray: 1, alpha: 1),
                CGColor(gray: 1, alpha: 0),
            ]
            viewportMaskLayer.startPoint = CGPoint(x: 0.5, y: 1)
            viewportMaskLayer.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.mask = viewportMaskLayer
            updateViewportMaskGeometry()
        }

        private func updateViewportMaskGeometry() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            viewportMaskLayer.frame = bounds
            let topFadeEndLocation: CGFloat
            if bounds.height > 0 {
                topFadeEndLocation = min(
                    viewportBottomFadeStartLocation,
                    viewportTopEdgeFadeDistance / bounds.height
                )
            } else {
                topFadeEndLocation = viewportBottomFadeStartLocation
            }
            viewportMaskLayer.locations = [
                0,
                NSNumber(value: Double(topFadeEndLocation)),
                NSNumber(value: Double(viewportBottomFadeStartLocation)),
                1,
            ]
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                startDisplayLink()
            } else {
                stopDisplayLink()
            }
        }

        // MARK: Update Entry Point

        func update(lyrics: Lyrics, highlightedLineIndex: Int?, mainFontSize: CGFloat, translationFontSize: CGFloat) {
            let newSignature = LayoutSignature(lyrics: lyrics)
            let fontsChanged = mainFontSize != self.mainFontSize || translationFontSize != self.translationFontSize
            self.lyrics = lyrics
            self.mainFontSize = mainFontSize
            self.translationFontSize = translationFontSize

            if newSignature != signature {
                signature = newSignature
                rebuildLineViews()
                relayout()
                highlightedOriginalIndex = nil
                applyHighlight(originalIndex: resolveRenderedIndex(highlightedLineIndex), animated: false)
                if instrumentalView != nil {
                    let currentTime = selectedPlayer.playbackTime + lyrics.adjustedTimeDelay
                    if currentTime < introEndTime {
                        centerOnInstrumentalDots(animated: false)
                    }
                }
                return
            }

            if fontsChanged {
                for view in enabledLineViews {
                    view.updateFonts(mainFontSize: mainFontSize, translationFontSize: translationFontSize)
                }
                relayout()
                if let highlighted = highlightedOriginalIndex {
                    centerLine(originalIndex: highlighted, animated: false)
                }
            }

            let resolvedIndex = resolveRenderedIndex(highlightedLineIndex)
            if resolvedIndex != highlightedOriginalIndex {
                applyHighlight(originalIndex: resolvedIndex, animated: true)
            }

            // When following resumes together with a data update, snap back to
            // the current line. (Resumes that happen without a data update — the
            // countdown completing — are handled by `resumeFollowingIfNeeded()`,
            // called from the view controller's `interactionState.onChange`.)
            let isFollowing = interactionState?.isFollowing ?? true
            if isFollowing, !wasFollowing, let highlighted = highlightedOriginalIndex {
                centerLine(originalIndex: highlighted, animated: true)
            }
            wasFollowing = isFollowing
        }

        /// Re-center when the interaction state returns to following outside of a
        /// data update (e.g. the countdown completing). Driven by the view
        /// controller's `interactionState.onChange`, since there is no longer a
        /// SwiftUI `updateNSView` to trigger it.
        func resumeFollowingIfNeeded() {
            let isFollowing = interactionState?.isFollowing ?? true
            if isFollowing, !wasFollowing, let highlighted = highlightedOriginalIndex {
                centerLine(originalIndex: highlighted, animated: true)
            }
            wasFollowing = isFollowing
        }

        /// Maps an original `lyrics.lines` index (which AppController computes
        /// over `enabled` lines only) to an index that actually has a rendered
        /// view (we additionally drop empty-content lines). During an
        /// enabled-but-empty interlude line, this keeps the previous sung line
        /// highlighted, anchored, and filled instead of dropping the highlight.
        private func resolveRenderedIndex(_ index: Int?) -> Int? {
            guard let index else { return nil }
            if lineViewByOriginalIndex[index] != nil {
                return index
            }
            return enabledOriginalIndices.last(where: { $0 <= index })
        }

        private func refreshTranslations() {
            guard !enabledLineViews.isEmpty else { return }
            for view in enabledLineViews {
                view.refreshTranslation()
            }
            relayout()
            if let highlighted = highlightedOriginalIndex {
                centerLine(originalIndex: highlighted, animated: false)
            }
        }

        // MARK: Build

        private func rebuildLineViews() {
            lastHighlightedPosition = nil
            lastLineTransitionTime = nil
            pendingInteractiveTargetOriginalIndex = nil
            lineTransitionCoordinator.cancel(scrollView: scrollView)
            enabledLineViews.forEach { $0.removeFromSuperview() }
            enabledLineViews.removeAll()
            lineViewByOriginalIndex.removeAll()
            enabledOriginalIndices.removeAll()

            guard let lyrics else { return }

            var enabledPosition = 0
            for (originalIndex, line) in lyrics.lines.enumerated() where line.enabled && !line.content.isEmpty {
                let view = SyncedLyricsLineView()
                view.configure(
                    line: line,
                    originalIndex: originalIndex,
                    enabledPosition: enabledPosition,
                    mainFontSize: mainFontSize,
                    translationFontSize: translationFontSize
                )
                view.alphaValue = 0.55
                view.onTap = { [weak self] tappedLine in
                    guard let self else { return }
                    self.pendingInteractiveTargetOriginalIndex = originalIndex
                    self.onSeek?(tappedLine.position + 0.01)
                    self.interactionState?.returnToFollowing()
                }
                documentView.addSubview(view)
                enabledLineViews.append(view)
                lineViewByOriginalIndex[originalIndex] = view
                enabledOriginalIndices.append(originalIndex)
                enabledPosition += 1
            }

            // Intro "•••" indicator when the first vocal line starts late.
            instrumentalView?.removeFromSuperview()
            instrumentalView = nil
            introEndTime = 0
            if let firstIndex = enabledOriginalIndices.first {
                let firstPosition = lyrics.lines[firstIndex].position
                let currentTime = selectedPlayer.playbackTime + lyrics.adjustedTimeDelay
                // Only while we are actually still inside the intro, so opening
                // the panel mid-song doesn't flash the dots then collapse them.
                if firstPosition > introGapThreshold, currentTime < firstPosition {
                    let view = SyncedLyricsInstrumentalView()
                    documentView.addSubview(view)
                    instrumentalView = view
                    introEndTime = firstPosition
                }
            }

            // Mid-song interlude indicators between word-timed lines whose gap
            // (next line start − this line's sung end) exceeds the threshold.
            interludeSegments.forEach { $0.view.removeFromSuperview() }
            interludeSegments.removeAll()
            for position in enabledOriginalIndices.indices.dropLast() {
                let line = lyrics.lines[enabledOriginalIndices[position]]
                guard let duration = line.timetagDuration, duration > 0 else { continue }
                let lineEnd = line.position + duration
                let nextStart = lyrics.lines[enabledOriginalIndices[position + 1]].position
                if nextStart - lineEnd > interludeGapThreshold {
                    let view = SyncedLyricsInstrumentalView()
                    documentView.addSubview(view)
                    interludeSegments.append(InterludeSegment(view: view, startTime: lineEnd, endTime: nextStart, afterEnabledPosition: position))
                }
            }
        }

        // MARK: Layout

        override func layout() {
            super.layout()
            if layer?.mask !== viewportMaskLayer {
                layer?.mask = viewportMaskLayer
            }
            updateViewportMaskGeometry()
            scrollView.frame = bounds
            if bounds.size != lastLaidOutSize {
                relayout()
                if let highlighted = highlightedOriginalIndex {
                    centerLine(originalIndex: highlighted, animated: false)
                }
            }
        }

        private func relayout() {
            let width = bounds.width
            let clipHeight = bounds.height
            guard width > 0 else { return }

            let topContentInset = enabledLineViews.first.map { lineView in
                selectedLineTopInset(for: lineView)
            } ?? 0
            var cursorY = topContentInset
            if let instrumentalView {
                let dotsHeight = instrumentalView.preferredHeight
                cursorY = max(topContentInset, (clipHeight - dotsHeight) / 2)
                instrumentalView.frame = NSRect(x: 0, y: cursorY, width: width, height: dotsHeight)
                cursorY += dotsHeight
            }
            let interludeByPosition = Dictionary(
                interludeSegments.map { ($0.afterEnabledPosition, $0.view) },
                uniquingKeysWith: { first, _ in first }
            )
            for (position, view) in enabledLineViews.enumerated() {
                let height = view.preferredHeight(forWidth: width)
                view.frame = NSRect(x: 0, y: cursorY, width: width, height: height)
                cursorY += height
                if let interludeView = interludeByPosition[position] {
                    let dotsHeight = interludeView.preferredHeight
                    interludeView.frame = NSRect(x: 0, y: cursorY, width: width, height: dotsHeight)
                    cursorY += dotsHeight
                }
            }
            let bottomContentInset = max(0, clipHeight - topContentInset)
            let totalHeight = cursorY + bottomContentInset
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(totalHeight, clipHeight))
            lastLaidOutSize = bounds.size
        }

        // MARK: Highlight

        private func applyHighlight(originalIndex: Int?, animated: Bool) {
            if let old = highlightedOriginalIndex, let view = lineViewByOriginalIndex[old] {
                view.setHighlighted(false)
            }
            highlightedOriginalIndex = originalIndex
            if let new = originalIndex, let view = lineViewByOriginalIndex[new] {
                view.setHighlighted(true)
            }
            if !animated {
                lastHighlightedPosition = originalIndex.flatMap { lineViewByOriginalIndex[$0]?.enabledPosition }
                lastLineTransitionTime = nil
            }
            let isFollowing = interactionState?.isFollowing ?? true
            if isFollowing, let new = originalIndex {
                if animated, window != nil {
                    advanceFollowing(toOriginalIndex: new)
                } else {
                    centerLine(originalIndex: new, animated: false)
                }
            }
            updateDistances(animated: animated)
        }

        /// Move to a newly highlighted line while following. A large noninteractive
        /// jump snaps instantly, a rapid sequence settles the clip as a unit, and a
        /// normal advance runs the row cascade restored from the SwiftUI renderer.
        private func advanceFollowing(toOriginalIndex originalIndex: Int) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let newPosition = view.enabledPosition
            let usesInteractiveSpring = pendingInteractiveTargetOriginalIndex == originalIndex
            pendingInteractiveTargetOriginalIndex = nil
            let isJump = lastHighlightedPosition.map { abs(newPosition - $0) > scrollJumpThreshold } ?? true
            let currentLineTransitionTime = lineTransitionTimeProvider()
            let isRapid = lastLineTransitionTime.map { previousLineTransitionTime in
                let elapsedTime = currentLineTransitionTime - previousLineTransitionTime
                return elapsedTime >= 0 && elapsedTime < LineTransitionPlan.rapidTransitionThreshold
            } ?? false
            lastHighlightedPosition = newPosition
            lastLineTransitionTime = currentLineTransitionTime

            if usesInteractiveSpring {
                centerLine(originalIndex: originalIndex, animated: true, usesInteractiveSpring: true)
            } else if isJump {
                centerLine(originalIndex: originalIndex, animated: false)
            } else if isRapid {
                settleLine(originalIndex: originalIndex)
            } else {
                cascadeLine(originalIndex: originalIndex)
            }
        }

        private func updateDistances(animated: Bool) {
            let highlightedPosition = highlightedOriginalIndex.flatMap { lineViewByOriginalIndex[$0]?.enabledPosition }
            let visibleBounds = scrollView.documentVisibleRect.insetBy(
                dx: 0,
                dy: -scrollView.documentVisibleRect.height * 0.5
            )
            var visibleLinePositions = Set(enabledLineViews.compactMap { lineView in
                lineView.frame.intersects(visibleBounds) ? lineView.enabledPosition : nil
            })
            if let highlightedPosition {
                visibleLinePositions.insert(highlightedPosition)
            }
            let blurPlan = LineBlurPlan.make(
                visibleLinePositions: visibleLinePositions,
                selectedLinePosition: highlightedPosition
            )
            for view in enabledLineViews {
                let isSelected = highlightedPosition.map { view.enabledPosition == $0 } ?? false
                // Every non-selected line sits at one flat opacity no matter how
                // far from the selected one it is — measured off a Music 26.5.2
                // recording, stroke peaks hold at ~0.5 luminance from one line
                // away to four. Depth comes from the blur, not an opacity ramp;
                // the ramp this replaces sank the bottom of the panel into the
                // background.
                let target: CGFloat = isSelected ? 1.0 : 0.55
                if animated {
                    view.animateAlpha(to: target, duration: 0.5)
                } else {
                    view.alphaValue = target
                }
                // `deselectedTransform` is the identity (no whole-line scale) — kept
                // for the active line staying at 1.0.
                view.setLineSelected(isSelected, animated: animated)
                // Music keeps an explicit contextual set rather than treating
                // every non-selected row as blurred. Rows inside the current
                // rendering context use one fixed radius; rows outside it return
                // to zero so they do not retain stale filter state.
                let targetBlurRadius = blurPlan.blurredLinePositions.contains(view.enabledPosition)
                    ? blurPlan.radius
                    : 0
                view.setLineBlurRadius(targetBlurRadius, animated: animated)
            }
        }

        // MARK: Scrolling

        private func cascadeLine(originalIndex: Int) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let springTiming = SpringTimingParameters(
                dampingRatio: LineTransitionPlan.cascadeSpringDampingRatio,
                period: LineTransitionPlan.cascadeSpringPeriod
            )
            let configuration = LineCascadeConfiguration(
                selectedLinePosition: view.enabledPosition,
                springTiming: springTiming,
                settleDuration: LineTransitionPlan.cascadeSettleDuration,
                stagger: LineTransitionPlan.cascadeStagger,
                aboveLineCount: LineTransitionPlan.cascadeAboveLineCount,
                belowLineCount: LineTransitionPlan.cascadeBelowLineCount
            )
            lineTransitionCoordinator.transitionLines(
                scrollView: scrollView,
                lineViews: enabledLineViews,
                targetClipVerticalOrigin: clampedClipVerticalOrigin(for: view),
                configuration: configuration,
                animated: window != nil
            )
        }

        private func settleLine(originalIndex: Int) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let timing = SpringTimingParameters(
                dampingRatio: LineTransitionPlan.rapidSettleDampingRatio,
                period: LineTransitionPlan.rapidSettleSpringPeriod
            )
            lineTransitionCoordinator.transitionClip(
                scrollView: scrollView,
                targetClipVerticalOrigin: clampedClipVerticalOrigin(for: view),
                timing: timing,
                animated: window != nil
            )
        }

        private func centerLine(
            originalIndex: Int,
            animated: Bool,
            usesInteractiveSpring: Bool = false
        ) {
            guard let view = lineViewByOriginalIndex[originalIndex] else { return }
            let targetClipVerticalOrigin = clampedClipVerticalOrigin(for: view)
            let timing = usesInteractiveSpring
                ? SpringTimingParameters(
                    mass: LineTransitionPlan.interactiveSpringMass,
                    stiffness: LineTransitionPlan.interactiveSpringStiffness,
                    damping: LineTransitionPlan.interactiveSpringDamping
                )
                : SpringTimingParameters(
                    mass: LineTransitionPlan.normalSpringMass,
                    stiffness: LineTransitionPlan.normalSpringStiffness,
                    damping: LineTransitionPlan.normalSpringDamping
                )
            lineTransitionCoordinator.transitionClip(
                scrollView: scrollView,
                targetClipVerticalOrigin: targetClipVerticalOrigin,
                timing: timing,
                animated: animated && window != nil
            )
        }

        private func centerOnInstrumentalDots(animated: Bool) {
            guard let instrumentalView else { return }
            anchorClip(toCenterVerticalPosition: instrumentalView.frame.midY, animated: animated)
        }

        /// Scroll so an instrumental indicator's vertical centre sits at the
        /// vertical centre of the viewport.
        private func anchorClip(toCenterVerticalPosition centerVerticalPosition: CGFloat, animated: Bool) {
            let targetVerticalOrigin = clampedClipVerticalOrigin(forCenterVerticalPosition: centerVerticalPosition)
            let timing = SpringTimingParameters(
                mass: LineTransitionPlan.normalSpringMass,
                stiffness: LineTransitionPlan.normalSpringStiffness,
                damping: LineTransitionPlan.normalSpringDamping
            )
            lineTransitionCoordinator.transitionClip(
                scrollView: scrollView,
                targetClipVerticalOrigin: targetVerticalOrigin,
                timing: timing,
                animated: animated && window != nil
            )
        }

        private func clampedClipVerticalOrigin(forCenterVerticalPosition centerVerticalPosition: CGFloat) -> CGFloat {
            let visibleHeight = scrollView.contentView.bounds.height
            let maximumVerticalOrigin = max(0, documentView.frame.height - visibleHeight)
            return min(max(0, centerVerticalPosition - visibleHeight / 2), maximumVerticalOrigin)
        }

        private func clampedClipVerticalOrigin(for lineView: SyncedLyricsLineView) -> CGFloat {
            let visibleHeight = scrollView.contentView.bounds.height
            let maximumVerticalOrigin = max(0, documentView.frame.height - visibleHeight)
            let topInset = selectedLineTopInset(for: lineView)
            return min(
                max(0, lineView.frame.minY - topInset),
                maximumVerticalOrigin
            )
        }

        private func selectedLineTopInset(for lineView: SyncedLyricsLineView) -> CGFloat {
            LineTransitionPlan.selectedLineTopInset(
                visibleHeight: scrollView.contentView.bounds.height,
                firstBaselineOffset: lineView.mainTextFirstBaselineOffset
            )
        }

        @objc private func userWillScroll() {
            // The user took over — abandon the in-flight auto-scroll spring so it
            // does not keep moving content under the drag.
            lineTransitionCoordinator.cancel(scrollView: scrollView)
            interactionState?.userDidScroll()
        }

        // MARK: Display Link (per-frame karaoke driver)

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            // MSDisplayLink wraps CADisplayLink (macOS 14+) and CVDisplayLink (older)
            // behind a single back-deployable Combine-friendly API, so the karaoke
            // driver runs on every supported macOS version.
            let link = DisplayLink()
            link.delegatingObject(self)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink = nil
        }

        private func handleDisplayLink() {
            // Resolve the lyrics time once per frame from the player STATE
            // (`lyricsDisplayTime`) — the canonical source every other lyrics view
            // uses, accurate while playing and (now) stable when paused. Everything
            // below uses this single value.
            resolvedPlaybackTime = selectedPlayer.playbackState.lyricsDisplayTime(
                trackDuration: selectedPlayer.currentTrack?.duration
            )
            // Nothing here advances a transition: Core Animation owns the clip
            // spring, so it keeps moving at the display's own rate even when this
            // callback is late.
            updateIntroDotsIfNeeded()
            updateInterludesIfNeeded()

            guard let lyrics,
                  let highlighted = highlightedOriginalIndex,
                  highlighted < lyrics.lines.count,
                  let view = lineViewByOriginalIndex[highlighted] else { return }
            let line = lyrics.lines[highlighted]
            let elapsed = resolvedPlaybackTime + lyrics.adjustedTimeDelay - line.position
            view.updateKaraoke(
                elapsedTime: elapsed,
                lineDuration: lineDuration(forOriginalIndex: highlighted),
                mode: karaokeMode
            )
        }

        private func updateIntroDotsIfNeeded() {
            guard let instrumentalView, let lyrics else { return }
            let currentTime = resolvedPlaybackTime + lyrics.adjustedTimeDelay
            if currentTime < introEndTime {
                let fraction = introEndTime > 0 ? CGFloat(currentTime / introEndTime) : 0
                instrumentalView.setProgress(fraction)
            } else {
                collapseIntroDots()
            }
        }

        private func updateInterludesIfNeeded() {
            guard !interludeSegments.isEmpty, let lyrics else { return }
            let currentTime = resolvedPlaybackTime + lyrics.adjustedTimeDelay
            var activeSegment: InterludeSegment?
            for segment in interludeSegments {
                if currentTime < segment.startTime {
                    segment.view.setProgress(0)
                } else if currentTime >= segment.endTime {
                    segment.view.setProgress(1)
                } else {
                    let span = segment.endTime - segment.startTime
                    segment.view.setProgress(span > 0 ? CGFloat((currentTime - segment.startTime) / span) : 0)
                    activeSegment = segment
                }
            }
            // During an interlude, keep the dots centered (the previous line
            // stays highlighted but the focus is the upcoming-break indicator).
            if let activeSegment, interactionState?.isFollowing ?? true {
                anchorClip(toCenterVerticalPosition: activeSegment.view.frame.midY, animated: true)
            }
        }

        private func collapseIntroDots() {
            guard let view = instrumentalView else { return }
            instrumentalView = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                view.animator().alphaValue = 0
            } completionHandler: {
                view.removeFromSuperview()
            }
            relayout()
            if interactionState?.isFollowing ?? true {
                if let highlighted = highlightedOriginalIndex {
                    centerLine(originalIndex: highlighted, animated: true)
                } else if let firstIndex = enabledOriginalIndices.first {
                    centerLine(originalIndex: firstIndex, animated: true)
                }
            }
        }

        private func lineDuration(forOriginalIndex index: Int) -> TimeInterval {
            guard let lyrics else { return 5 }
            if let duration = lyrics.lines[index].timetagDuration, duration > 0 {
                return duration
            }
            if let nextIndex = enabledOriginalIndices.first(where: { $0 > index }) {
                return lyrics.lines[nextIndex].position - lyrics.lines[index].position
            }
            return 5
        }

        // MARK: - Layout Signature

        /// Cheap track-change detector: rebuild line views only when the set of
        /// enabled lines actually changes, not on every highlight/resize update.
        private struct LayoutSignature: Equatable {
            var count: Int
            var contentHash: Int

            init(lyrics: Lyrics) {
                var enabledCount = 0
                var hasher = Hasher()
                hasher.combine(lyrics.idTags[.init("lang")] ?? "")
                for line in lyrics.lines where line.enabled && !line.content.isEmpty {
                    enabledCount += 1
                    hasher.combine(line.content)
                    hasher.combine(line.position)
                    // Fold in timing + translation so a same-track source swap
                    // that keeps the same text but changes word timings or the
                    // translation still triggers a rebuild.
                    let timetag = line.attachments.timetag
                    hasher.combine(timetag?.tags.count ?? -1)
                    hasher.combine(timetag?.duration ?? -1)
                    hasher.combine(line.attachments.synchronizedTextTiming?.description ?? "")
                    hasher.combine(line.attachments.translation() ?? "")
                }
                self.count = enabledCount
                self.contentHash = hasher.finalize()
            }
        }

        // MARK: - Flipped Document View

        private final class FlippedDocumentView: NSView {
            override var isFlipped: Bool {
                true
            }
        }
    }
}

extension AppleMusicLyrics.SyncedLyricsContainerView: DisplayLinkDelegate {
    func synchronization(context: DisplayLinkCallbackContext) {
        handleDisplayLink()
    }
}
