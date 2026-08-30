import CoreGraphics
import Foundation
import Testing
@testable import AppleMusicLyricsPanel

struct ArtworkGradientConfigurationTests {
    @Test func defaultsKeepRenderingWorkBounded() {
        let configuration = AppleMusicLyrics.ArtworkGradientConfiguration()

        #expect(configuration.paletteColorCount == 5)
        #expect(configuration.sampleDimension == 44)
        #expect(configuration.clusteringCentroidCount == 8)
        #expect(configuration.clusteringIterationCount == 10)
        #expect(configuration.drawableScale == 0.35)
        #expect(configuration.darkOverlayOpacity == 0.3)
        #expect(configuration.paletteTransitionDuration == 1.2)
    }

    @Test func drawableSizeUsesARestrictedFractionOfNativeBackingPixels() {
        let configuration = AppleMusicLyrics.ArtworkGradientConfiguration()

        let drawablePixelSize = configuration.drawablePixelSize(
            forNativeBackingSize: CGSize(width: 2000, height: 1200)
        )

        #expect(drawablePixelSize == CGSize(width: 700, height: 420))
    }

    @Test func drawableSizeNeverCreatesAZeroSizedMetalTexture() {
        let configuration = AppleMusicLyrics.ArtworkGradientConfiguration()

        let drawablePixelSize = configuration.drawablePixelSize(
            forNativeBackingSize: .zero
        )

        #expect(drawablePixelSize == CGSize(width: 1, height: 1))
    }
}

struct ArtworkGradientRequestStateTests {
    @Test func artworkIsSubmittedOncePerTrackAndStaleResultsAreRejected() throws {
        var requestState = AppleMusicLyrics.ArtworkGradientRequestState()

        let observedFirstTrack = requestState.observeTrackIdentity("first-track")
        #expect(observedFirstTrack)
        let firstGenerationCandidate = requestState.beginArtworkRequest()
        let firstGeneration = try #require(firstGenerationCandidate)
        let repeatedGenerationCandidate = requestState.beginArtworkRequest()
        #expect(repeatedGenerationCandidate == nil)
        #expect(requestState.acceptsResult(generation: firstGeneration))

        let observedSecondTrack = requestState.observeTrackIdentity("second-track")
        #expect(observedSecondTrack)
        #expect(!requestState.acceptsResult(generation: firstGeneration))
        let secondGenerationCandidate = requestState.beginArtworkRequest()
        let secondGeneration = try #require(secondGenerationCandidate)

        #expect(secondGeneration > firstGeneration)
        #expect(requestState.acceptsResult(generation: secondGeneration))
    }

    @Test func repeatedTrackIdentityDoesNotInvalidateTheCurrentPalette() {
        var requestState = AppleMusicLyrics.ArtworkGradientRequestState()

        let observedInitialTrack = requestState.observeTrackIdentity("same-track")
        let observedRepeatedTrack = requestState.observeTrackIdentity("same-track")

        #expect(observedInitialTrack)
        #expect(!observedRepeatedTrack)
    }
}

struct ArtworkGradientPaletteTests {
    @Test func normalizationAlwaysProducesTheShaderColorCount() {
        let sourceColors = [
            AppleMusicLyrics.ArtworkGradientColor(red: 0.8, green: 0.2, blue: 0.1),
            AppleMusicLyrics.ArtworkGradientColor(red: 0.1, green: 0.3, blue: 0.8),
        ]

        let normalizedColors = AppleMusicLyrics.ArtworkGradientPalette.normalized(
            sourceColors,
            colorCount: 5
        )

        #expect(normalizedColors.count == 5)
        #expect(normalizedColors[0] == sourceColors[0])
        #expect(normalizedColors[1] == sourceColors[1])
        #expect(normalizedColors[2] == sourceColors[0])
    }

    @Test func emptyExtractionUsesTheBuiltInFallbackPalette() {
        let normalizedColors = AppleMusicLyrics.ArtworkGradientPalette.normalized(
            [],
            colorCount: 5
        )

        #expect(normalizedColors == AppleMusicLyrics.ArtworkGradientPalette.fallback)
    }

    @Test func splitColorArtworkRetainsBothDominantColorFamilies() throws {
        let coreGraphicsImage = try #require(Self.makeSplitColorArtworkImage())

        let extractedColors = try #require(
            AppleMusicLyrics.ArtworkGradientPaletteExtractor.dominantColors(
                from: coreGraphicsImage
            )
        )

        #expect(!extractedColors.isEmpty)
        #expect(extractedColors.count <= 5)
        #expect(extractedColors.contains { color in
            color.red > color.green && color.red > color.blue
        })
        #expect(extractedColors.contains { color in
            color.blue > color.red && color.blue > color.green
        })
        #expect(extractedColors.allSatisfy { color in
            (0 ... 1).contains(color.red)
                && (0 ... 1).contains(color.green)
                && (0 ... 1).contains(color.blue)
                && color.alpha == 1
        })
    }

    private static func makeSplitColorArtworkImage() -> CGImage? {
        let imageWidth = 320
        let imageHeight = 160
        let bytesPerPixel = 4
        let bytesPerRow = imageWidth * bytesPerPixel
        var pixelBytes = [UInt8](repeating: 0, count: bytesPerRow * imageHeight)

        for verticalPixelIndex in 0 ..< imageHeight {
            for horizontalPixelIndex in 0 ..< imageWidth {
                let pixelByteIndex = verticalPixelIndex * bytesPerRow
                    + horizontalPixelIndex * bytesPerPixel
                if horizontalPixelIndex < imageWidth / 2 {
                    pixelBytes[pixelByteIndex] = 230
                    pixelBytes[pixelByteIndex + 1] = 42
                    pixelBytes[pixelByteIndex + 2] = 58
                } else {
                    pixelBytes[pixelByteIndex] = 35
                    pixelBytes[pixelByteIndex + 1] = 78
                    pixelBytes[pixelByteIndex + 2] = 230
                }
                pixelBytes[pixelByteIndex + 3] = 255
            }
        }

        guard let dataProvider = CGDataProvider(data: Data(pixelBytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }
        return CGImage(
            width: imageWidth,
            height: imageHeight,
            bitsPerComponent: 8,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

struct ArtworkGradientRenderingPolicyTests {
    @Test func frameRateFollowsTheCurrentScreenAndFallsBackToSixty() {
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: nil
            ) == 60
        )
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: 0
            ) == 60
        )
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: 60
            ) == 60
        )
        #expect(
            AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: 120
            ) == 120
        )
    }

    @Test func visibleStationaryWindowRendersContinuously() {
        let shouldRenderContinuously = AppleMusicLyrics.ArtworkGradientRenderingPolicy.shouldRenderContinuously(
            isPresentationVisible: true,
            isAttachedToWindow: true,
            isWindowVisible: true,
            isWindowOccluded: false,
            isViewHidden: false,
            isWindowDragging: false,
            isLiveResizing: false,
            shouldReduceMotion: false
        )

        #expect(shouldRenderContinuously)
    }

    @Test(arguments: [
        (false, true, true, false, false, false, false, false),
        (true, false, true, false, false, false, false, false),
        (true, true, false, false, false, false, false, false),
        (true, true, true, true, false, false, false, false),
        (true, true, true, false, true, false, false, false),
        (true, true, true, false, false, true, false, false),
        (true, true, true, false, false, false, true, false),
        (true, true, true, false, false, false, false, true),
    ])
    func unavailableOrMotionRestrictedStatesPauseContinuousRendering(
        isPresentationVisible: Bool,
        isAttachedToWindow: Bool,
        isWindowVisible: Bool,
        isWindowOccluded: Bool,
        isViewHidden: Bool,
        isWindowDragging: Bool,
        isLiveResizing: Bool,
        shouldReduceMotion: Bool
    ) {
        let shouldRenderContinuously = AppleMusicLyrics.ArtworkGradientRenderingPolicy.shouldRenderContinuously(
            isPresentationVisible: isPresentationVisible,
            isAttachedToWindow: isAttachedToWindow,
            isWindowVisible: isWindowVisible,
            isWindowOccluded: isWindowOccluded,
            isViewHidden: isViewHidden,
            isWindowDragging: isWindowDragging,
            isLiveResizing: isLiveResizing,
            shouldReduceMotion: shouldReduceMotion
        )

        #expect(!shouldRenderContinuously)
    }
}

struct ArtworkGradientAnimationClockTests {
    @Test func pausedWallClockTimeDoesNotAdvanceTheGradient() {
        var animationClock = AppleMusicLyrics.ArtworkGradientAnimationClock()

        animationClock.setPaused(false, timestamp: 10)
        #expect(animationClock.elapsedTime(at: 12) == 2)
        animationClock.setPaused(true, timestamp: 12)
        #expect(animationClock.elapsedTime(at: 50) == 2)
        animationClock.setPaused(false, timestamp: 50)
        #expect(animationClock.elapsedTime(at: 51.5) == 3.5)
    }
}
