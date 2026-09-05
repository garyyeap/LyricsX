#include <metal_stdlib>
using namespace metal;

struct ArtworkCompositionVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

struct ArtworkBackdropMeshVertex {
    float2 clipSpacePosition;
    float2 destinationClipSpacePosition;
    float2 textureCoordinate;
};

struct ArtworkBackdropMeshVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

constant float2 artworkBackdropClipSpacePositions[6] = {
    float2(-1.0, -1.0),
    float2(-1.0, 1.0),
    float2(1.0, 1.0),
    float2(-1.0, -1.0),
    float2(1.0, 1.0),
    float2(1.0, -1.0),
};

constant float2 artworkBackdropInstanceTranslations[3] = {
    float2(0.0, 0.0),
    float2(-0.5, 0.7),
    float2(-0.95, -0.7),
};

constant float artworkBackdropRotationPeriods[3] = {60.0, 45.0, 35.0};

float2 artworkBackdropRotateClockwise(float2 position, float rotationSine, float rotationCosine) {
    return float2(
        position.x * rotationCosine + position.y * rotationSine,
        position.y * rotationCosine - position.x * rotationSine
    );
}

vertex ArtworkCompositionVertexOutput artworkBackdropCompositionVertex(
    uint vertexIdentifier [[vertex_id]],
    uint instanceIdentifier [[instance_id]],
    constant float4 &compositionParameters [[buffer(0)]]
) {
    float2 clipSpacePosition = artworkBackdropClipSpacePositions[vertexIdentifier];
    float2 textureCoordinate = clipSpacePosition * 0.5 + 0.5;
    textureCoordinate.y = 1.0 - textureCoordinate.y;
    float rotationAngle = compositionParameters.y * (M_PI_F * 2.0)
        / artworkBackdropRotationPeriods[instanceIdentifier];
    float rotationSine = sin(rotationAngle);
    float rotationCosine = cos(rotationAngle);
    // Music applies view * rotation * model translation * rotation.
    float2 artworkPosition = artworkBackdropRotateClockwise(
        clipSpacePosition,
        rotationSine,
        rotationCosine
    );
    artworkPosition += artworkBackdropInstanceTranslations[instanceIdentifier];
    artworkPosition = artworkBackdropRotateClockwise(
        artworkPosition,
        rotationSine,
        rotationCosine
    );
    artworkPosition.y *= compositionParameters.x;

    ArtworkCompositionVertexOutput output;
    output.position = float4(artworkPosition, 0.0, 1.0);
    output.textureCoordinate = textureCoordinate;
    return output;
}

fragment float4 artworkBackdropCompositionFragment(
    ArtworkCompositionVertexOutput input [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    texture2d<float> destinationTexture [[texture(1)]],
    constant float4 &compositionParameters [[buffer(0)]]
) {
    constexpr sampler artworkSampler(
        address::clamp_to_edge,
        filter::linear,
        mip_filter::linear
    );
    float4 sourceColor = sourceTexture.sample(
        artworkSampler,
        input.textureCoordinate
    );
    float4 destinationColor = destinationTexture.sample(
        artworkSampler,
        input.textureCoordinate
    );
    float3 artworkColor = mix(
        sourceColor,
        destinationColor,
        clamp(compositionParameters.z, 0.0, 1.0)
    ).rgb;
    float luminosity = dot(artworkColor, float3(0.3, 0.59, 0.11));
    return float4(mix(float3(luminosity), artworkColor, compositionParameters.w), 1.0);
}

vertex ArtworkBackdropMeshVertexOutput artworkBackdropMeshVertex(
    const device ArtworkBackdropMeshVertex *vertices [[buffer(0)]],
    constant float4 &motionParameters [[buffer(1)]],
    uint vertexIdentifier [[vertex_id]]
) {
    ArtworkBackdropMeshVertex meshVertex = vertices[vertexIdentifier];
    float elapsedTime = motionParameters.x;
    float warpPhase = elapsedTime * M_PI_F / motionParameters.y;
    float interpolationPosition = acos(clamp(sin(warpPhase), -1.0, 1.0)) / M_PI_F;
    float interpolationProgress = smoothstep(0.0, 1.0, interpolationPosition);
    float2 position = mix(
        meshVertex.clipSpacePosition,
        meshVertex.destinationClipSpacePosition,
        interpolationProgress
    );

    ArtworkBackdropMeshVertexOutput output;
    output.position = float4(position, 0.0, 1.0);
    output.textureCoordinate = (meshVertex.textureCoordinate - 0.5) * motionParameters.z + 0.5;
    return output;
}

fragment float4 artworkBackdropFinalFragment(
    ArtworkBackdropMeshVertexOutput input [[stage_in]],
    texture2d<float> blurredArtworkTexture [[texture(0)]],
    constant float4 &appearanceParameters [[buffer(0)]],
    constant float2 &colorRangeParameters [[buffer(1)]]
) {
    constexpr sampler artworkSampler(
        address::clamp_to_edge,
        filter::linear
    );
    float3 artworkColor = blurredArtworkTexture.sample(
        artworkSampler,
        input.textureCoordinate
    ).rgb;
    float luminosity = dot(artworkColor, float3(0.3, 0.59, 0.11));
    float3 saturatedColor = mix(
        float3(luminosity),
        artworkColor,
        appearanceParameters.x
    );
    // Limit highlights before the dark scrim so saturation cannot cancel it.
    saturatedColor = min(saturatedColor, appearanceParameters.w);
    saturatedColor *= 1.0 - clamp(appearanceParameters.y, 0.0, 1.0);
    saturatedColor -= appearanceParameters.z;
    return float4(clamp(saturatedColor, colorRangeParameters.x, colorRangeParameters.y), 1.0);
}
