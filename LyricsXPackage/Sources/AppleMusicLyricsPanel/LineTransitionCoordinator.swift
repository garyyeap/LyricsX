import AppKit
import QuartzCore

extension AppleMusicLyrics {
    /// Owns the single clip-bounds spring used by lyric line transitions.
    ///
    /// Selection does not change any row's model frame in this renderer, so a
    /// normal advance must not synthesize the scroll displacement again on every
    /// row. The clip receives its final AppKit-owned bounds first, then one Core
    /// Animation spring preserves presentation continuity until it reaches that
    /// model endpoint.
    @MainActor
    final class LineTransitionCoordinator {
        static let clipBoundsAnimationKey = "AppleMusicLyrics.clipBounds"

        private var targetClipVerticalOrigin: CGFloat?

        func transition(
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

        /// Stops presentation-only motion and commits the currently visible clip
        /// origin so direct manipulation starts without a jump.
        func cancel(scrollView: NSScrollView) {
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

        private func setClipOrigin(_ verticalOrigin: CGFloat, scrollView: NSScrollView) {
            let clipView = scrollView.contentView
            clipView.setBoundsOrigin(CGPoint(x: clipView.bounds.origin.x, y: verticalOrigin))
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}
