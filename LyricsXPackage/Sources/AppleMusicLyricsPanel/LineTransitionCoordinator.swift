import AppKit
import QuartzCore

extension AppleMusicLyrics {
    struct LineCascadeConfiguration {
        let selectedLinePosition: Int
        let springTiming: SpringTimingParameters
        let settleDuration: TimeInterval
        let stagger: TimeInterval
        let aboveLineCount: Int
        let belowLineCount: Int
    }

    /// Coordinates both kinds of lyric movement without asking the display link
    /// to step either one.
    ///
    /// Direct manipulation and rapid changes move the clip on one render-server
    /// spring. A normal line advance instead restores the previous SwiftUI
    /// cascade: the clip model snaps to its new anchor, nearby row layers receive
    /// the opposite presentation displacement, and those rows settle back with a
    /// stagger. Their AppKit-owned model positions never change.
    @MainActor
    final class LineTransitionCoordinator {
        static let clipBoundsAnimationKey = "AppleMusicLyrics.clipBounds"
        static let linePositionAnimationKey = "AppleMusicLyrics.lineCascadePosition"

        private var targetClipVerticalOrigin: CGFloat?
        private var animatedLineLayers: [CALayer] = []

        func transitionClip(
            scrollView: NSScrollView,
            targetClipVerticalOrigin: CGFloat,
            timing: SpringTimingParameters,
            animated: Bool
        ) {
            let clipView = scrollView.contentView
            guard animated, let clipLayer = clipView.layer else {
                cancel(scrollView: scrollView)
                setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)
                return
            }

            if self.targetClipVerticalOrigin.map({ abs($0 - targetClipVerticalOrigin) <= 0.5 }) == true,
               clipLayer.animation(forKey: Self.clipBoundsAnimationKey) != nil {
                return
            }

            let visibleClipVerticalOrigin = (clipLayer.presentation() ?? clipLayer).bounds.origin.y
            removeLineAnimations()
            self.targetClipVerticalOrigin = targetClipVerticalOrigin

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)
            CATransaction.commit()

            guard abs(visibleClipVerticalOrigin - targetClipVerticalOrigin) > 0.5 else {
                clipLayer.removeAnimation(forKey: Self.clipBoundsAnimationKey)
                return
            }

            let animation = timing.makeAnimation(keyPath: "bounds.origin.y")
            animation.fromValue = visibleClipVerticalOrigin
            animation.toValue = targetClipVerticalOrigin
            animation.isRemovedOnCompletion = true
            animation.preferredFrameRateRange = LyricsSpecs.preferredFrameRateRange
            clipLayer.add(animation, forKey: Self.clipBoundsAnimationKey)
        }

        func transitionLines(
            scrollView: NSScrollView,
            lineViews: [SyncedLyricsLineView],
            targetClipVerticalOrigin: CGFloat,
            configuration: LineCascadeConfiguration,
            animated: Bool
        ) {
            let clipView = scrollView.contentView
            guard animated, let clipLayer = clipView.layer else {
                cancel(scrollView: scrollView)
                setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)
                return
            }

            let (aboveLineViews, springingLineViews) = lineGroups(
                from: lineViews,
                configuration: configuration
            )
            let transitioningLineViews = aboveLineViews + springingLineViews
            let visibleLineVerticalPositions = visibleVerticalPositions(for: transitioningLineViews)
            let visibleClipVerticalOrigin = (clipLayer.presentation() ?? clipLayer).bounds.origin.y
            let compensatingDisplacement = targetClipVerticalOrigin - visibleClipVerticalOrigin

            self.targetClipVerticalOrigin = nil
            clipLayer.removeAnimation(forKey: Self.clipBoundsAnimationKey)
            removeLineAnimations()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setClipOrigin(targetClipVerticalOrigin, scrollView: scrollView)

            guard abs(compensatingDisplacement) > 0.5 else {
                CATransaction.commit()
                return
            }

            addSettlingAnimations(
                to: aboveLineViews,
                visibleVerticalPositions: visibleLineVerticalPositions,
                compensatingDisplacement: compensatingDisplacement,
                duration: configuration.settleDuration
            )
            addSpringAnimations(
                to: springingLineViews,
                visibleVerticalPositions: visibleLineVerticalPositions,
                compensatingDisplacement: compensatingDisplacement,
                configuration: configuration
            )
            CATransaction.commit()

            animatedLineLayers = transitioningLineViews.compactMap(\.layer)
        }

        private func lineGroups(
            from lineViews: [SyncedLyricsLineView],
            configuration: LineCascadeConfiguration
        ) -> (above: [SyncedLyricsLineView], springing: [SyncedLyricsLineView]) {
            let aboveLineViews = Array(lineViews
                .filter { $0.enabledPosition < configuration.selectedLinePosition }
                .suffix(max(0, configuration.aboveLineCount)))
            let springingLineViews = Array(lineViews
                .filter { $0.enabledPosition >= configuration.selectedLinePosition }
                .prefix(max(0, configuration.belowLineCount)))
            return (aboveLineViews, springingLineViews)
        }

        private func visibleVerticalPositions(
            for lineViews: [SyncedLyricsLineView]
        ) -> [ObjectIdentifier: CGFloat] {
            lineViews.reduce(into: [ObjectIdentifier: CGFloat]()) { positions, lineView in
                guard let lineLayer = lineView.layer else { return }
                positions[ObjectIdentifier(lineLayer)] = (lineLayer.presentation() ?? lineLayer).position.y
            }
        }

        private func addSettlingAnimations(
            to lineViews: [SyncedLyricsLineView],
            visibleVerticalPositions: [ObjectIdentifier: CGFloat],
            compensatingDisplacement: CGFloat,
            duration: TimeInterval
        ) {
            for lineView in lineViews {
                guard let lineLayer = lineView.layer,
                      let visibleLineVerticalPosition = visibleVerticalPositions[ObjectIdentifier(lineLayer)]
                else {
                    continue
                }
                let animation = CABasicAnimation(keyPath: "position.y")
                animation.fromValue = visibleLineVerticalPosition + compensatingDisplacement
                animation.toValue = lineLayer.position.y
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                configureLineAnimation(animation)
                lineLayer.add(animation, forKey: Self.linePositionAnimationKey)
            }
        }

        private func addSpringAnimations(
            to lineViews: [SyncedLyricsLineView],
            visibleVerticalPositions: [ObjectIdentifier: CGFloat],
            compensatingDisplacement: CGFloat,
            configuration: LineCascadeConfiguration
        ) {
            let currentMediaTime = CACurrentMediaTime()
            for (lineOffset, lineView) in lineViews.enumerated() {
                guard let lineLayer = lineView.layer,
                      let visibleLineVerticalPosition = visibleVerticalPositions[ObjectIdentifier(lineLayer)]
                else {
                    continue
                }
                let animation = configuration.springTiming.makeAnimation(keyPath: "position.y")
                animation.fromValue = visibleLineVerticalPosition + compensatingDisplacement
                animation.toValue = lineLayer.position.y
                animation.beginTime = lineLayer.convertTime(currentMediaTime, from: nil)
                    + configuration.stagger * TimeInterval(lineOffset + 2)
                configureLineAnimation(animation)
                lineLayer.add(animation, forKey: Self.linePositionAnimationKey)
            }
        }

        private func configureLineAnimation(_ animation: CAPropertyAnimation) {
            animation.fillMode = .both
            animation.isRemovedOnCompletion = true
            animation.preferredFrameRateRange = LyricsSpecs.preferredFrameRateRange
        }

        /// Stops presentation-only motion and commits the currently visible clip
        /// origin so direct manipulation starts without a jump.
        func cancel(scrollView: NSScrollView) {
            removeLineAnimations()
            targetClipVerticalOrigin = nil
            let clipView = scrollView.contentView
            guard let clipLayer = clipView.layer,
                  clipLayer.animation(forKey: Self.clipBoundsAnimationKey) != nil else {
                return
            }
            let visibleClipVerticalOrigin = (clipLayer.presentation() ?? clipLayer).bounds.origin.y
            clipLayer.removeAnimation(forKey: Self.clipBoundsAnimationKey)
            setClipOrigin(visibleClipVerticalOrigin, scrollView: scrollView)
        }

        private func removeLineAnimations() {
            for lineLayer in animatedLineLayers {
                lineLayer.removeAnimation(forKey: Self.linePositionAnimationKey)
            }
            animatedLineLayers.removeAll(keepingCapacity: true)
        }

        private func setClipOrigin(_ verticalOrigin: CGFloat, scrollView: NSScrollView) {
            let clipView = scrollView.contentView
            clipView.setBoundsOrigin(CGPoint(x: clipView.bounds.origin.x, y: verticalOrigin))
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}
