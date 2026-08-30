import CoreGraphics
import Foundation

extension AppleMusicLyrics {
    struct ArtworkGradientColor: Equatable, Sendable {
        let red: Float
        let green: Float
        let blue: Float
        let alpha: Float

        init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        var linearColorVector: SIMD4<Float> {
            SIMD4(
                Self.linearComponent(fromStandardRedGreenBlueComponent: red),
                Self.linearComponent(fromStandardRedGreenBlueComponent: green),
                Self.linearComponent(fromStandardRedGreenBlueComponent: blue),
                alpha
            )
        }

        private static func linearComponent(fromStandardRedGreenBlueComponent component: Float) -> Float {
            if component <= 0.04045 {
                return component / 12.92
            }
            return pow((component + 0.055) / 1.055, 2.4)
        }
    }

    struct ArtworkGradientConfiguration: Sendable {
        let paletteColorCount: Int
        let sampleDimension: Int
        let clusteringCentroidCount: Int
        let clusteringIterationCount: Int
        let saturationMultiplier: CGFloat
        let saturationOffset: CGFloat
        let brightnessMultiplier: CGFloat
        let brightnessOffset: CGFloat
        let minimumBrightness: CGFloat
        let maximumBrightness: CGFloat
        let drawableScale: CGFloat
        let darkOverlayOpacity: Float
        let grainAmount: Float
        let paletteTransitionDuration: TimeInterval
        let artworkAbsenceFallbackDelay: TimeInterval

        init(
            sampleDimension: Int = 44,
            clusteringCentroidCount: Int = 8,
            clusteringIterationCount: Int = 10,
            saturationMultiplier: CGFloat = 1.35,
            saturationOffset: CGFloat = 0.05,
            brightnessMultiplier: CGFloat = 0.72,
            brightnessOffset: CGFloat = 0.08,
            minimumBrightness: CGFloat = 0.24,
            maximumBrightness: CGFloat = 0.72,
            drawableScale: CGFloat = 0.35,
            darkOverlayOpacity: Float = 0.3,
            grainAmount: Float = 0.008,
            paletteTransitionDuration: TimeInterval = 1.2,
            artworkAbsenceFallbackDelay: TimeInterval = 1.2
        ) {
            self.paletteColorCount = 5
            self.sampleDimension = sampleDimension
            self.clusteringCentroidCount = clusteringCentroidCount
            self.clusteringIterationCount = clusteringIterationCount
            self.saturationMultiplier = saturationMultiplier
            self.saturationOffset = saturationOffset
            self.brightnessMultiplier = brightnessMultiplier
            self.brightnessOffset = brightnessOffset
            self.minimumBrightness = minimumBrightness
            self.maximumBrightness = maximumBrightness
            self.drawableScale = drawableScale
            self.darkOverlayOpacity = darkOverlayOpacity
            self.grainAmount = grainAmount
            self.paletteTransitionDuration = paletteTransitionDuration
            self.artworkAbsenceFallbackDelay = artworkAbsenceFallbackDelay
        }

        func drawablePixelSize(forNativeBackingSize nativeBackingSize: CGSize) -> CGSize {
            guard nativeBackingSize.width > 0,
                  nativeBackingSize.height > 0,
                  drawableScale > 0
            else {
                return CGSize(width: 1, height: 1)
            }

            return CGSize(
                width: max(1, (nativeBackingSize.width * drawableScale).rounded()),
                height: max(1, (nativeBackingSize.height * drawableScale).rounded())
            )
        }
    }

    enum ArtworkGradientPalette {
        static let fallback = [
            ArtworkGradientColor(red: 0.22, green: 0.52, blue: 0.57),
            ArtworkGradientColor(red: 0.25, green: 0.37, blue: 0.66),
            ArtworkGradientColor(red: 0.49, green: 0.31, blue: 0.62),
            ArtworkGradientColor(red: 0.23, green: 0.57, blue: 0.47),
            ArtworkGradientColor(red: 0.62, green: 0.39, blue: 0.32),
        ]

        static func normalized(
            _ colors: [ArtworkGradientColor],
            colorCount: Int,
            fallbackColors: [ArtworkGradientColor] = fallback
        ) -> [ArtworkGradientColor] {
            guard colorCount > 0 else { return [] }

            let availableColors: [ArtworkGradientColor] = if colors.isEmpty {
                fallbackColors.isEmpty
                    ? [ArtworkGradientColor(red: 0.18, green: 0.2, blue: 0.24)]
                    : fallbackColors
            } else {
                colors
            }

            return (0 ..< colorCount).map { colorIndex in
                availableColors[colorIndex % availableColors.count]
            }
        }
    }

    struct ArtworkGradientRequestState {
        private(set) var currentTrackIdentity: String?
        private(set) var generation: UInt64 = 0
        private(set) var hasSubmittedArtwork = false
        private var hasReceivedTrackIdentity = false

        mutating func observeTrackIdentity(_ trackIdentity: String?) -> Bool {
            guard !hasReceivedTrackIdentity || trackIdentity != currentTrackIdentity else {
                return false
            }

            hasReceivedTrackIdentity = true
            currentTrackIdentity = trackIdentity
            hasSubmittedArtwork = false
            generation &+= 1
            return true
        }

        mutating func beginArtworkRequest() -> UInt64? {
            guard !hasSubmittedArtwork else { return nil }
            hasSubmittedArtwork = true
            generation &+= 1
            return generation
        }

        func acceptsResult(generation: UInt64) -> Bool {
            self.generation == generation
        }
    }

    enum ArtworkGradientRenderingPolicy {
        static func preferredFramesPerSecond(
            screenMaximumFramesPerSecond: Int?
        ) -> Int {
            guard let screenMaximumFramesPerSecond,
                  screenMaximumFramesPerSecond > 0
            else {
                return 60
            }

            return screenMaximumFramesPerSecond
        }

        static func canRenderFrame(
            isPresentationVisible: Bool,
            isAttachedToWindow: Bool,
            isWindowVisible: Bool,
            isWindowOccluded: Bool,
            isViewHidden: Bool,
            isWindowDragging: Bool,
            isLiveResizing: Bool
        ) -> Bool {
            isPresentationVisible
                && isAttachedToWindow
                && isWindowVisible
                && !isWindowOccluded
                && !isViewHidden
                && !isWindowDragging
                && !isLiveResizing
        }

        static func shouldRenderContinuously(
            isPresentationVisible: Bool,
            isAttachedToWindow: Bool,
            isWindowVisible: Bool,
            isWindowOccluded: Bool,
            isViewHidden: Bool,
            isWindowDragging: Bool,
            isLiveResizing: Bool,
            shouldReduceMotion: Bool
        ) -> Bool {
            canRenderFrame(
                isPresentationVisible: isPresentationVisible,
                isAttachedToWindow: isAttachedToWindow,
                isWindowVisible: isWindowVisible,
                isWindowOccluded: isWindowOccluded,
                isViewHidden: isViewHidden,
                isWindowDragging: isWindowDragging,
                isLiveResizing: isLiveResizing
            ) && !shouldReduceMotion
        }
    }

    struct ArtworkGradientAnimationClock {
        private(set) var accumulatedElapsedTime: TimeInterval = 0
        private var resumeTimestamp: TimeInterval?

        mutating func setPaused(_ shouldPause: Bool, timestamp: TimeInterval) {
            if shouldPause {
                guard let resumeTimestamp else { return }
                accumulatedElapsedTime += max(0, timestamp - resumeTimestamp)
                self.resumeTimestamp = nil
            } else if resumeTimestamp == nil {
                resumeTimestamp = timestamp
            }
        }

        func elapsedTime(at timestamp: TimeInterval) -> TimeInterval {
            guard let resumeTimestamp else { return accumulatedElapsedTime }
            return accumulatedElapsedTime + max(0, timestamp - resumeTimestamp)
        }
    }
}
