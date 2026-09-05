import simd

extension AppleMusicLyrics {
    enum ArtworkBackdropMeshPresets {
        static let variantCount = 5

        static func controlPoints(variant: Int) -> (
            source: [SIMD2<Float>],
            destination: [SIMD2<Float>]
        ) {
            var source = (0 ..< 36).map { pointIndex in
                SIMD2<Float>(Float(pointIndex % 6) / 5, Float(pointIndex / 6) / 5)
            }
            let changes = variants[min(variantCount - 1, max(0, variant))]
            for (pointIndex, position) in changes.source {
                source[pointIndex] = position
            }
            var destination = source
            for (pointIndex, position) in changes.destination {
                destination[pointIndex] = position
            }
            return (source, destination)
        }

        private struct ControlPointChanges {
            let source: [Int: SIMD2<Float>]
            let destination: [Int: SIMD2<Float>]
        }

        /// Normalized control points recovered from Music 26.6. Each destination
        /// contains only the points that move relative to its source surface.
        private static let variants: [ControlPointChanges] = [
            ControlPointChanges(
                source: [
                    7: SIMD2(-0.0933, 0.4),
                    10: SIMD2(0.3653, 0.1335),
                    13: SIMD2(0.4232, 0.359),
                    14: SIMD2(0.3429, 0.5349),
                    16: SIMD2(0.832, 0.4148),
                    20: SIMD2(0.2293, 0.7775),
                    21: SIMD2(0.7829, 0.5595),
                    22: SIMD2(0.6514, 0.7302),
                    26: SIMD2(0.28, 0.9195),
                    27: SIMD2(0.4773, 0.8),
                    31: SIMD2(0.6514, 1.1073),
                    33: SIMD2(1, 1.0317),
                    34: SIMD2(1, 1.1302),
                ],
                destination: [
                    10: SIMD2(0.8587, 0.2234),
                    13: SIMD2(0.4526, 0.6053),
                ]
            ),
            ControlPointChanges(
                source: [
                    7: SIMD2(0.3265, 0.3839),
                    9: SIMD2(0.462, 0.3424),
                    10: SIMD2(0.683, 0.2797),
                    15: SIMD2(0.6, 0.4903),
                    16: SIMD2(0.6574, 0.4903),
                    17: SIMD2(1.1357, 0.4),
                    18: SIMD2(-0.1173, 0.4597),
                    19: SIMD2(0.3771, 0.4384),
                    20: SIMD2(0.6415, 0.5947),
                    21: SIMD2(0.8254, 0.6935),
                    22: SIMD2(0.9334, 0.5862),
                    24: SIMD2(-0.0437, 0.6533),
                    25: SIMD2(0.2, 0.6618),
                    26: SIMD2(0.683, 0.7362),
                    27: SIMD2(0.8139, 0.833),
                    28: SIMD2(0.9104, 0.8085),
                ],
                destination: [
                    7: SIMD2(0.2437, 0.4392),
                    13: SIMD2(0.1494, 0.4787),
                    14: SIMD2(0.4, 0.5063),
                    15: SIMD2(0.6966, 0.516),
                    16: SIMD2(0.8139, 0.4478),
                    19: SIMD2(0.2437, 0.6085),
                    20: SIMD2(0.6414, 0.5756),
                ]
            ),
            ControlPointChanges(
                source: [
                    3: SIMD2(0.7465, -0.0935),
                    4: SIMD2(0.9702, -0.0872),
                    5: SIMD2(1.5935, -0.0308),
                    6: SIMD2(-0.1675, 0.2878),
                    7: SIMD2(0.7185, 0.3087),
                    8: SIMD2(0.5952, 0.0728),
                    9: SIMD2(0.7823, 0.0815),
                    10: SIMD2(0.9318, 0.301),
                    11: SIMD2(1.1369, 0.3756),
                    13: SIMD2(0.3295, 0.4607),
                    14: SIMD2(0.7823, 0.3087),
                    15: SIMD2(0.7465, 0.365),
                    16: SIMD2(0.9514, 0.4305),
                    17: SIMD2(1.1514, 0.4424),
                    20: SIMD2(0.3295, 0.4424),
                    21: SIMD2(0.5703, 0.5),
                    22: SIMD2(0.7887, 0.4847),
                    25: SIMD2(0.2414, 0.7926),
                    26: SIMD2(0.0418, 0.7303),
                    27: SIMD2(0.5952, 0.4688),
                    28: SIMD2(0.9433, 0.6929),
                ],
                destination: [
                    7: SIMD2(0.5414, 0.2825),
                    13: SIMD2(0.2881, 0.4479),
                    15: SIMD2(0.8363, 0.3661),
                    19: SIMD2(0.177, 0.6),
                    20: SIMD2(0.4, 0.4775),
                    26: SIMD2(0.1499, 0.7324),
                    27: SIMD2(0.5952, 0.5623),
                ]
            ),
            ControlPointChanges(
                source: [
                    3: SIMD2(0.7465, -0.0935),
                    4: SIMD2(0.9702, -0.0872),
                    5: SIMD2(1.5935, -0.0308),
                    6: SIMD2(-0.1675, 0.2878),
                    7: SIMD2(0.7185, 0.3087),
                    8: SIMD2(0.5952, 0.0728),
                    9: SIMD2(0.7823, 0.0815),
                    10: SIMD2(0.9318, 0.301),
                    11: SIMD2(1.1369, 0.3756),
                    13: SIMD2(0.3295, 0.4607),
                    14: SIMD2(0.7823, 0.3087),
                    15: SIMD2(0.7465, 0.365),
                    16: SIMD2(0.9514, 0.4305),
                    17: SIMD2(1.1514, 0.4424),
                    20: SIMD2(0.3295, 0.4424),
                    21: SIMD2(0.5703, 0.5),
                    22: SIMD2(0.7887, 0.4847),
                    25: SIMD2(0.2414, 0.7926),
                    26: SIMD2(0.0418, 0.7303),
                    27: SIMD2(0.5952, 0.4688),
                    28: SIMD2(0.9433, 0.6929),
                ],
                destination: [
                    7: SIMD2(0.5414, 0.2825),
                    13: SIMD2(0.2881, 0.4479),
                    15: SIMD2(0.8363, 0.3661),
                    19: SIMD2(0.177, 0.6),
                    20: SIMD2(0.4, 0.4775),
                    26: SIMD2(0.1499, 0.7324),
                    27: SIMD2(0.5952, 0.5623),
                ]
            ),
            ControlPointChanges(
                source: [
                    0: SIMD2(-0.2351, -0.0967),
                    1: SIMD2(0.2135, -0.1414),
                    2: SIMD2(0.9221, -0.0908),
                    3: SIMD2(0.9221, -0.0685),
                    4: SIMD2(1.3027, 0.0253),
                    5: SIMD2(1.2351, 0.1786),
                    6: SIMD2(-0.3768, 0.1851),
                    8: SIMD2(0.6615, 0.3146),
                    9: SIMD2(0.9543, 0),
                    10: SIMD2(0.6969, 0.1911),
                    14: SIMD2(0.0776, 0.2318),
                    16: SIMD2(0.6615, 0.3851),
                    19: SIMD2(0.1291, 0.6),
                    21: SIMD2(0.4, 0.4304),
                    22: SIMD2(0.4264, 0.5792),
                    23: SIMD2(1.2029, 0.8188),
                    24: SIMD2(-0.1192, 1),
                    25: SIMD2(0.6, 0.8),
                    26: SIMD2(0.4264, 0.8104),
                    31: SIMD2(0.0776, 1.0283),
                    35: SIMD2(1.1868, 1.0283),
                ],
                destination: [
                    7: SIMD2(0.1839, 0.2),
                    8: SIMD2(0.7034, 0.2952),
                    10: SIMD2(0.7775, 0.3339),
                    13: SIMD2(0.0357, 0.5369),
                    19: SIMD2(0.2, 0.6878),
                    21: SIMD2(0.5, 0.5896),
                    22: SIMD2(0.6454, 0.6878),
                    25: SIMD2(0.6193, 0.9027),
                ]
            ),
        ]
    }
}
