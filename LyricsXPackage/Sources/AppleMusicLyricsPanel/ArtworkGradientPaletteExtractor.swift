import CoreGraphics
import Foundation

extension AppleMusicLyrics {
    enum ArtworkGradientPaletteExtractor {
        private struct RedGreenBlueColorComponents: Equatable {
            var red: CGFloat
            var green: CGFloat
            var blue: CGFloat
        }

        private struct ColorCluster {
            var center: RedGreenBlueColorComponents
            var weight: Int
        }

        private struct PaletteCandidate {
            let color: ArtworkGradientColor
            let weight: Int
            let saturation: CGFloat
        }

        static func dominantColors(
            from coreGraphicsImage: CGImage,
            configuration: ArtworkGradientConfiguration = ArtworkGradientConfiguration()
        ) -> [ArtworkGradientColor]? {
            guard let sampledPixels = downsampledPixels(
                from: coreGraphicsImage,
                dimension: configuration.sampleDimension
            ), !sampledPixels.isEmpty else {
                return nil
            }

            let clusters = clusterPixelsByNearestCentroid(
                pixels: sampledPixels,
                centroidCount: configuration.clusteringCentroidCount,
                iterationCount: configuration.clusteringIterationCount
            )
            let candidates = clusters.compactMap { cluster -> PaletteCandidate? in
                guard cluster.weight > 0 else { return nil }

                let hueSaturationBrightness = hueSaturationBrightness(from: cluster.center)
                let adjustedSaturation = min(
                    1,
                    hueSaturationBrightness.saturation * configuration.saturationMultiplier
                        + configuration.saturationOffset
                )
                let adjustedBrightness = min(
                    configuration.maximumBrightness,
                    max(
                        configuration.minimumBrightness,
                        hueSaturationBrightness.brightness * configuration.brightnessMultiplier
                            + configuration.brightnessOffset
                    )
                )
                let adjustedColor = redGreenBlueColorComponents(
                    hue: hueSaturationBrightness.hue,
                    saturation: adjustedSaturation,
                    brightness: adjustedBrightness
                )
                return PaletteCandidate(
                    color: ArtworkGradientColor(
                        red: Float(adjustedColor.red),
                        green: Float(adjustedColor.green),
                        blue: Float(adjustedColor.blue)
                    ),
                    weight: cluster.weight,
                    saturation: adjustedSaturation
                )
            }
            guard !candidates.isEmpty else { return nil }

            let minimumAccentWeight = max(1, sampledPixels.count / 50)
            var selectedCandidateIndices: [Int] = []

            for candidateIndex in candidates.indices.sorted(by: {
                candidates[$0].weight > candidates[$1].weight
            }) {
                if selectedCandidateIndices.count >= min(3, configuration.paletteColorCount) {
                    break
                }
                selectedCandidateIndices.append(candidateIndex)
            }

            for candidateIndex in candidates.indices.sorted(by: {
                candidates[$0].saturation > candidates[$1].saturation
            }) {
                if selectedCandidateIndices.count >= configuration.paletteColorCount {
                    break
                }
                if candidates[candidateIndex].weight >= minimumAccentWeight,
                   !selectedCandidateIndices.contains(candidateIndex) {
                    selectedCandidateIndices.append(candidateIndex)
                }
            }

            for candidateIndex in candidates.indices.sorted(by: {
                candidates[$0].weight > candidates[$1].weight
            }) where selectedCandidateIndices.count < configuration.paletteColorCount {
                if !selectedCandidateIndices.contains(candidateIndex) {
                    selectedCandidateIndices.append(candidateIndex)
                }
            }

            let selectedColors = selectedCandidateIndices.map { candidateIndex in
                candidates[candidateIndex].color
            }
            return selectedColors.isEmpty ? nil : selectedColors
        }

        private static func downsampledPixels(
            from coreGraphicsImage: CGImage,
            dimension: Int
        ) -> [RedGreenBlueColorComponents]? {
            guard dimension > 0 else { return nil }

            let bitmapWidth = dimension
            let bitmapHeight = dimension
            let bytesPerPixel = 4
            let bytesPerRow = bitmapWidth * bytesPerPixel
            var pixelBytes = [UInt8](repeating: 0, count: bytesPerRow * bitmapHeight)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: &pixelBytes,
                      width: bitmapWidth,
                      height: bitmapHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                          | CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return nil
            }

            context.interpolationQuality = .medium
            context.draw(
                coreGraphicsImage,
                in: CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight)
            )

            var sampledPixels: [RedGreenBlueColorComponents] = []
            sampledPixels.reserveCapacity(bitmapWidth * bitmapHeight)
            for pixelByteIndex in stride(from: 0, to: pixelBytes.count, by: bytesPerPixel) {
                let alpha = CGFloat(pixelBytes[pixelByteIndex + 3]) / 255
                guard alpha > 0.1 else { continue }

                let unpremultiplicationScale = 1 / alpha
                sampledPixels.append(RedGreenBlueColorComponents(
                    red: min(1, CGFloat(pixelBytes[pixelByteIndex]) / 255 * unpremultiplicationScale),
                    green: min(1, CGFloat(pixelBytes[pixelByteIndex + 1]) / 255 * unpremultiplicationScale),
                    blue: min(1, CGFloat(pixelBytes[pixelByteIndex + 2]) / 255 * unpremultiplicationScale)
                ))
            }
            return sampledPixels
        }

        private static func clusterPixelsByNearestCentroid(
            pixels: [RedGreenBlueColorComponents],
            centroidCount: Int,
            iterationCount: Int
        ) -> [ColorCluster] {
            let effectiveCentroidCount = min(max(0, centroidCount), pixels.count)
            guard effectiveCentroidCount > 0 else { return [] }

            var centers = initialCenters(
                pixels: pixels,
                centroidCount: effectiveCentroidCount
            )
            var assignments = [Int](repeating: 0, count: pixels.count)

            for _ in 0 ..< max(1, iterationCount) {
                for (pixelIndex, pixel) in pixels.enumerated() {
                    var nearestSquaredDistance = CGFloat.greatestFiniteMagnitude
                    var nearestCenterIndex = 0
                    for (centerIndex, center) in centers.enumerated() {
                        let candidateSquaredDistance = squaredDistance(pixel, center)
                        if candidateSquaredDistance < nearestSquaredDistance {
                            nearestSquaredDistance = candidateSquaredDistance
                            nearestCenterIndex = centerIndex
                        }
                    }
                    assignments[pixelIndex] = nearestCenterIndex
                }

                var componentSums = [RedGreenBlueColorComponents](
                    repeating: RedGreenBlueColorComponents(red: 0, green: 0, blue: 0),
                    count: effectiveCentroidCount
                )
                var assignmentCounts = [Int](repeating: 0, count: effectiveCentroidCount)
                for (pixelIndex, pixel) in pixels.enumerated() {
                    let assignedCenterIndex = assignments[pixelIndex]
                    componentSums[assignedCenterIndex].red += pixel.red
                    componentSums[assignedCenterIndex].green += pixel.green
                    componentSums[assignedCenterIndex].blue += pixel.blue
                    assignmentCounts[assignedCenterIndex] += 1
                }

                for centerIndex in centers.indices where assignmentCounts[centerIndex] > 0 {
                    let assignedPixelCount = CGFloat(assignmentCounts[centerIndex])
                    centers[centerIndex] = RedGreenBlueColorComponents(
                        red: componentSums[centerIndex].red / assignedPixelCount,
                        green: componentSums[centerIndex].green / assignedPixelCount,
                        blue: componentSums[centerIndex].blue / assignedPixelCount
                    )
                }
            }

            var clusterWeights = [Int](repeating: 0, count: effectiveCentroidCount)
            for assignedCenterIndex in assignments {
                clusterWeights[assignedCenterIndex] += 1
            }
            return centers.indices.map { centerIndex in
                ColorCluster(center: centers[centerIndex], weight: clusterWeights[centerIndex])
            }
        }

        private static func initialCenters(
            pixels: [RedGreenBlueColorComponents],
            centroidCount: Int
        ) -> [RedGreenBlueColorComponents] {
            var centers = [pixels[pixels.count / 2]]
            while centers.count < centroidCount {
                var farthestPixel = pixels[0]
                var farthestNearestSquaredDistance: CGFloat = -1
                for pixel in pixels {
                    var nearestSquaredDistance = CGFloat.greatestFiniteMagnitude
                    for center in centers {
                        nearestSquaredDistance = min(
                            nearestSquaredDistance,
                            squaredDistance(pixel, center)
                        )
                    }
                    if nearestSquaredDistance > farthestNearestSquaredDistance {
                        farthestNearestSquaredDistance = nearestSquaredDistance
                        farthestPixel = pixel
                    }
                }
                centers.append(farthestPixel)
            }
            return centers
        }

        private static func squaredDistance(
            _ firstColor: RedGreenBlueColorComponents,
            _ secondColor: RedGreenBlueColorComponents
        ) -> CGFloat {
            let redDifference = firstColor.red - secondColor.red
            let greenDifference = firstColor.green - secondColor.green
            let blueDifference = firstColor.blue - secondColor.blue
            return redDifference * redDifference
                + greenDifference * greenDifference
                + blueDifference * blueDifference
        }

        private static func hueSaturationBrightness(
            from color: RedGreenBlueColorComponents
        ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
            let maximumComponent = max(color.red, color.green, color.blue)
            let minimumComponent = min(color.red, color.green, color.blue)
            let componentRange = maximumComponent - minimumComponent
            let saturation = maximumComponent <= 0 ? 0 : componentRange / maximumComponent
            var hue: CGFloat = 0

            if componentRange > 0 {
                if maximumComponent == color.red {
                    hue = (color.green - color.blue) / componentRange
                } else if maximumComponent == color.green {
                    hue = 2 + (color.blue - color.red) / componentRange
                } else {
                    hue = 4 + (color.red - color.green) / componentRange
                }
                hue /= 6
                if hue < 0 {
                    hue += 1
                }
            }
            return (hue, saturation, maximumComponent)
        }

        private static func redGreenBlueColorComponents(
            hue: CGFloat,
            saturation: CGFloat,
            brightness: CGFloat
        ) -> RedGreenBlueColorComponents {
            let chroma = brightness * saturation
            let hueSector = hue * 6
            let secondaryComponent = chroma
                * (1 - abs(hueSector.truncatingRemainder(dividingBy: 2) - 1))
            let brightnessMatch = brightness - chroma

            let unshiftedComponents = switch hueSector {
            case 0 ..< 1:
                RedGreenBlueColorComponents(red: chroma, green: secondaryComponent, blue: 0)
            case 1 ..< 2:
                RedGreenBlueColorComponents(red: secondaryComponent, green: chroma, blue: 0)
            case 2 ..< 3:
                RedGreenBlueColorComponents(red: 0, green: chroma, blue: secondaryComponent)
            case 3 ..< 4:
                RedGreenBlueColorComponents(red: 0, green: secondaryComponent, blue: chroma)
            case 4 ..< 5:
                RedGreenBlueColorComponents(red: secondaryComponent, green: 0, blue: chroma)
            default:
                RedGreenBlueColorComponents(red: chroma, green: 0, blue: secondaryComponent)
            }

            return RedGreenBlueColorComponents(
                red: unshiftedComponents.red + brightnessMatch,
                green: unshiftedComponents.green + brightnessMatch,
                blue: unshiftedComponents.blue + brightnessMatch
            )
        }
    }
}
