#include <metal_stdlib>
using namespace metal;

struct ArtworkCompositionVertexOutput {
    float4 position [[position]];
    float2 sourceTextureCoordinate;
    float2 destinationTextureCoordinate;
};

struct ArtworkBackdropMeshVertex {
    float2 clipSpacePosition;
    float2 textureCoordinate;
};

struct ArtworkBackdropMeshVertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

constant float2 artworkBackdropClipSpacePositions[3] = {
    float2(-1.0, -1.0),
    float2(3.0, -1.0),
    float2(-1.0, 3.0),
};

float2 artworkBackdropAspectFilledTextureCoordinate(
    float2 textureCoordinate,
    float textureAspectRatio,
    float viewportAspectRatio,
    float rotationSine,
    float rotationCosine,
    float zoomScale
) {
    float2 centeredTextureCoordinate = textureCoordinate - 0.5;
    if (textureAspectRatio > viewportAspectRatio) {
        centeredTextureCoordinate.x *= viewportAspectRatio / textureAspectRatio;
    } else {
        centeredTextureCoordinate.y *= textureAspectRatio / viewportAspectRatio;
    }
    centeredTextureCoordinate *= zoomScale;
    centeredTextureCoordinate = float2(
        centeredTextureCoordinate.x * rotationCosine
            - centeredTextureCoordinate.y * rotationSine,
        centeredTextureCoordinate.x * rotationSine
            + centeredTextureCoordinate.y * rotationCosine
    );
    return centeredTextureCoordinate + 0.5;
}

vertex ArtworkCompositionVertexOutput artworkBackdropCompositionVertex(
    uint vertexIdentifier [[vertex_id]],
    constant float4 &aspectAndTransitionParameters [[buffer(0)]],
    constant float4 &rotationParameters [[buffer(1)]]
) {
    float2 clipSpacePosition = artworkBackdropClipSpacePositions[vertexIdentifier];
    float2 textureCoordinate = clipSpacePosition * 0.5 + 0.5;
    textureCoordinate.y = 1.0 - textureCoordinate.y;
    float sourceTextureAspectRatio = aspectAndTransitionParameters.x;
    float destinationTextureAspectRatio = aspectAndTransitionParameters.y;
    float viewportAspectRatio = aspectAndTransitionParameters.z;
    float rotationSine = rotationParameters.x;
    float rotationCosine = rotationParameters.y;
    float zoomScale = rotationParameters.z;

    ArtworkCompositionVertexOutput output;
    output.position = float4(clipSpacePosition, 0.0, 1.0);
    output.sourceTextureCoordinate = artworkBackdropAspectFilledTextureCoordinate(
        textureCoordinate,
        sourceTextureAspectRatio,
        viewportAspectRatio,
        rotationSine,
        rotationCosine,
        zoomScale
    );
    output.destinationTextureCoordinate = artworkBackdropAspectFilledTextureCoordinate(
        textureCoordinate,
        destinationTextureAspectRatio,
        viewportAspectRatio,
        -rotationSine,
        rotationCosine,
        zoomScale
    );
    return output;
}

fragment float4 artworkBackdropCompositionFragment(
    ArtworkCompositionVertexOutput input [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    texture2d<float> destinationTexture [[texture(1)]],
    constant float4 &aspectAndTransitionParameters [[buffer(0)]]
) {
    constexpr sampler artworkSampler(
        address::clamp_to_edge,
        filter::linear,
        mip_filter::linear
    );
    float4 sourceColor = sourceTexture.sample(
        artworkSampler,
        input.sourceTextureCoordinate
    );
    float4 destinationColor = destinationTexture.sample(
        artworkSampler,
        input.destinationTextureCoordinate
    );
    return mix(
        sourceColor,
        destinationColor,
        clamp(aspectAndTransitionParameters.w, 0.0, 1.0)
    );
}

vertex ArtworkBackdropMeshVertexOutput artworkBackdropMeshVertex(
    const device ArtworkBackdropMeshVertex *vertices [[buffer(0)]],
    constant float4 &motionParameters [[buffer(1)]],
    uint vertexIdentifier [[vertex_id]]
) {
    ArtworkBackdropMeshVertex meshVertex = vertices[vertexIdentifier];
    float elapsedTime = motionParameters.x;
    float horizontalAmplitude = motionParameters.y;
    float verticalAmplitude = motionParameters.z;
    float edgeAttenuation = sin(meshVertex.textureCoordinate.x * M_PI_F)
        * sin(meshVertex.textureCoordinate.y * M_PI_F);
    float horizontalOffset = sin(
        elapsedTime * 0.19 + meshVertex.textureCoordinate.y * M_PI_F * 2.0
    ) * horizontalAmplitude * edgeAttenuation;
    float verticalOffset = cos(
        elapsedTime * 0.16 + meshVertex.textureCoordinate.x * M_PI_F * 2.0
    ) * verticalAmplitude * edgeAttenuation;

    ArtworkBackdropMeshVertexOutput output;
    output.position = float4(meshVertex.clipSpacePosition, 0.0, 1.0);
    output.textureCoordinate = meshVertex.textureCoordinate
        + float2(horizontalOffset, verticalOffset);
    return output;
}

fragment float4 artworkBackdropFinalFragment(
    ArtworkBackdropMeshVertexOutput input [[stage_in]],
    texture2d<float> blurredArtworkTexture [[texture(0)]],
    constant float4 &appearanceParameters [[buffer(0)]]
) {
    constexpr sampler artworkSampler(
        address::clamp_to_edge,
        filter::linear
    );
    float3 artworkColor = blurredArtworkTexture.sample(
        artworkSampler,
        input.textureCoordinate
    ).rgb;
    float luminosity = dot(artworkColor, float3(0.2126, 0.7152, 0.0722));
    float3 saturatedColor = mix(
        float3(luminosity),
        artworkColor,
        appearanceParameters.x
    );
    saturatedColor = mix(
        saturatedColor,
        float3(1.0),
        clamp(appearanceParameters.z, 0.0, 1.0)
    );
    saturatedColor *= 1.0 - clamp(appearanceParameters.y, 0.0, 1.0);
    return float4(clamp(saturatedColor, 0.0, 1.0), 1.0);
}
