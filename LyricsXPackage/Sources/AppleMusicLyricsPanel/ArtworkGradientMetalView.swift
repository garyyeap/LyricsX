import AppKit
import MetalKit

extension AppleMusicLyrics {
    final class ArtworkGradientMetalView: MTKView, MTKViewDelegate {
        private let configuration: ArtworkGradientConfiguration
        private let renderer: ArtworkBackdropRenderer
        private var isFrameRenderingAllowed = false
        private var isDrawableResizingSuspended = false

        init(
            frame frameRect: NSRect,
            device metalDevice: MTLDevice,
            configuration: ArtworkGradientConfiguration,
            shaderLibrary: MTLLibrary? = nil
        ) throws {
            self.configuration = configuration
            self.renderer = try ArtworkBackdropRenderer(
                device: metalDevice,
                configuration: configuration,
                shaderLibrary: shaderLibrary
            )

            super.init(frame: frameRect, device: metalDevice)

            delegate = self
            framebufferOnly = true
            colorPixelFormat = renderer.drawablePixelFormat
            depthStencilPixelFormat = .invalid
            sampleCount = 1
            preferredFramesPerSecond = ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: nil
            )
            enableSetNeedsDisplay = false
            autoResizeDrawable = false
            presentsWithTransaction = false
            clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1)
            colorspace = nil
            isPaused = true
            updateDrawableSize()
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isOpaque: Bool {
            true
        }

        override func layout() {
            super.layout()
            updateDrawableSize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateDrawableSize()
        }

        func setRenderingState(
            isFrameRenderingAllowed: Bool,
            isContinuousRenderingEnabled: Bool
        ) {
            let stateChanged = self.isFrameRenderingAllowed != isFrameRenderingAllowed
                || isPaused == isContinuousRenderingEnabled
            guard stateChanged else { return }

            self.isFrameRenderingAllowed = isFrameRenderingAllowed
            isPaused = !isContinuousRenderingEnabled
            renderer.setRenderingState(
                isFrameRenderingAllowed: isFrameRenderingAllowed,
                isContinuousRenderingEnabled: isContinuousRenderingEnabled,
                preferredFramesPerSecond: preferredFramesPerSecond
            )
        }

        func setPreferredFramesPerSecond(_ framesPerSecond: Int) {
            let normalizedFramesPerSecond = max(1, framesPerSecond)
            guard preferredFramesPerSecond != normalizedFramesPerSecond else { return }

            let previousFramesPerSecond = preferredFramesPerSecond
            preferredFramesPerSecond = normalizedFramesPerSecond
            renderer.setPreferredFramesPerSecond(
                previousFramesPerSecond: previousFramesPerSecond,
                currentFramesPerSecond: normalizedFramesPerSecond
            )
        }

        func setArtworkTexture(
            _ artworkTexture: MTLTexture,
            averageLuminosity: Float,
            animated: Bool
        ) {
            renderer.enqueueArtworkTexture(
                artworkTexture,
                averageLuminosity: averageLuminosity,
                animated: animated
            )
            requestSingleFrame()
        }

        func setFallbackArtwork(animated: Bool) {
            renderer.enqueueFallbackTexture(animated: animated)
            requestSingleFrame()
        }

        func setDrawableResizingSuspended(_ isSuspended: Bool) {
            guard isDrawableResizingSuspended != isSuspended else { return }
            isDrawableResizingSuspended = isSuspended
            if !isSuspended {
                updateDrawableSize()
            }
        }

        func requestSingleFrame() {
            guard isFrameRenderingAllowed, isPaused else { return }
            draw()
        }

        func draw(in view: MTKView) {
            guard isFrameRenderingAllowed else { return }
            renderer.draw(in: view)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer.drawableSizeWillChange(size)
        }

        private func updateDrawableSize() {
            guard !isDrawableResizingSuspended else { return }

            let nativeBackingBounds = convertToBacking(bounds)
            let updatedDrawableSize = configuration.drawablePixelSize(
                forNativeBackingSize: nativeBackingBounds.size
            )
            guard drawableSize != updatedDrawableSize else { return }
            drawableSize = updatedDrawableSize
            if isPaused {
                requestSingleFrame()
            }
        }
    }
}
