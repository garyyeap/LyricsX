import Foundation
import simd

extension AppleMusicLyrics {
    struct ArtworkBackdropMeshVertex {
        let clipSpacePosition: SIMD2<Float>
        let textureCoordinate: SIMD2<Float>
    }

    struct ArtworkBackdropMeshTopology {
        let baseControlPointCount: Int
        let subdivisionLevel: Int

        init(baseControlPointCount: Int, subdivisionLevel: Int) {
            self.baseControlPointCount = max(2, baseControlPointCount)
            self.subdivisionLevel = min(8, max(0, subdivisionLevel))
        }

        var vertexCountPerDimension: Int {
            segmentCountPerDimension + 1
        }

        var vertexCount: Int {
            vertexCountPerDimension * vertexCountPerDimension
        }

        var indexCount: Int {
            segmentCountPerDimension * segmentCountPerDimension * 6
        }

        func makeVertices() -> [ArtworkBackdropMeshVertex] {
            let vertexCountPerDimension = vertexCountPerDimension
            let segmentCountPerDimension = segmentCountPerDimension
            return (0 ..< vertexCountPerDimension).flatMap { verticalVertexIndex in
                let verticalFraction = Float(verticalVertexIndex)
                    / Float(segmentCountPerDimension)
                return (0 ..< vertexCountPerDimension).map { horizontalVertexIndex in
                    let horizontalFraction = Float(horizontalVertexIndex)
                        / Float(segmentCountPerDimension)
                    return ArtworkBackdropMeshVertex(
                        clipSpacePosition: SIMD2(
                            horizontalFraction * 2 - 1,
                            1 - verticalFraction * 2
                        ),
                        textureCoordinate: SIMD2(
                            horizontalFraction,
                            verticalFraction
                        )
                    )
                }
            }
        }

        func makeIndices() -> [UInt32] {
            let vertexCountPerDimension = vertexCountPerDimension
            var indices = [UInt32]()
            indices.reserveCapacity(indexCount)

            for verticalSegmentIndex in 0 ..< segmentCountPerDimension {
                for horizontalSegmentIndex in 0 ..< segmentCountPerDimension {
                    let topLeftVertexIndex = UInt32(
                        verticalSegmentIndex * vertexCountPerDimension
                            + horizontalSegmentIndex
                    )
                    let topRightVertexIndex = topLeftVertexIndex + 1
                    let bottomLeftVertexIndex = topLeftVertexIndex
                        + UInt32(vertexCountPerDimension)
                    let bottomRightVertexIndex = bottomLeftVertexIndex + 1
                    indices.append(contentsOf: [
                        topLeftVertexIndex,
                        bottomLeftVertexIndex,
                        topRightVertexIndex,
                        topRightVertexIndex,
                        bottomLeftVertexIndex,
                        bottomRightVertexIndex,
                    ])
                }
            }
            return indices
        }

        private var segmentCountPerDimension: Int {
            (baseControlPointCount - 1) * (1 << subdivisionLevel)
        }
    }
}
