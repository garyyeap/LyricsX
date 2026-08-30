#include <metal_stdlib>
using namespace metal;

struct ArtworkGradientVertexOutput {
    float4 position [[position]];
    float2 normalizedPosition;
};

constant float2 artworkGradientClipSpacePositions[3] = {
    float2(-1.0, -1.0),
    float2(3.0, -1.0),
    float2(-1.0, 3.0),
};

constant float artworkGradientHorizontalPhases[5] = { 0.2, 1.7, 3.3, 4.8, 5.9 };
constant float artworkGradientVerticalPhases[5] = { 2.4, 4.1, 0.8, 5.3, 1.5 };
constant float artworkGradientMotionSpeeds[5] = { 0.071, 0.053, 0.061, 0.047, 0.057 };

vertex ArtworkGradientVertexOutput artworkGradientFullScreenVertex(
    uint vertexIdentifier [[vertex_id]]
) {
    ArtworkGradientVertexOutput output;
    float2 clipSpacePosition = artworkGradientClipSpacePositions[vertexIdentifier];
    output.position = float4(clipSpacePosition, 0.0, 1.0);
    output.normalizedPosition = clipSpacePosition * 0.5 + 0.5;
    return output;
}

fragment float4 artworkGradientFragment(
    ArtworkGradientVertexOutput input [[stage_in]],
    constant float4 *paletteColors [[buffer(0)]],
    constant float4 &renderingParameters [[buffer(1)]]
) {
    float elapsedTime = renderingParameters.x;
    float darkOverlayOpacity = renderingParameters.y;
    float grainAmount = renderingParameters.z;
    float aspectRatio = max(0.1, renderingParameters.w);
    float2 normalizedPosition = input.normalizedPosition;
    float3 weightedColor = float3(0.0);
    float3 averageColor = float3(0.0);
    float totalInfluence = 0.0;

    for (uint colorIndex = 0; colorIndex < 5; ++colorIndex) {
        float movementTime = elapsedTime * artworkGradientMotionSpeeds[colorIndex];
        float2 colorCenter = float2(
            0.5 + 0.43 * sin(movementTime + artworkGradientHorizontalPhases[colorIndex]),
            0.5 + 0.43 * sin(movementTime * 0.83 + artworkGradientVerticalPhases[colorIndex])
        );
        float2 positionDifference = normalizedPosition - colorCenter;
        positionDifference.x *= aspectRatio;
        float colorRadius = 0.42
            + 0.07 * sin(movementTime * 0.71 + artworkGradientHorizontalPhases[colorIndex]);
        float normalizedDistanceSquared = dot(positionDifference, positionDifference)
            / max(0.04, colorRadius * colorRadius);
        float influence = 1.0
            / (0.16 + normalizedDistanceSquared * normalizedDistanceSquared);

        weightedColor += paletteColors[colorIndex].rgb * influence;
        averageColor += paletteColors[colorIndex].rgb;
        totalInfluence += influence;
    }

    averageColor /= 5.0;
    float3 gradientColor = weightedColor / max(0.001, totalInfluence);
    gradientColor = mix(gradientColor, averageColor, 0.08);

    float staticGrain = fract(
        sin(dot(input.position.xy, float2(12.9898, 78.233))) * 43758.5453
    ) - 0.5;
    gradientColor += staticGrain * grainAmount;
    gradientColor *= 1.0 - clamp(darkOverlayOpacity, 0.0, 1.0);
    return float4(clamp(gradientColor, 0.0, 1.0), 1.0);
}
