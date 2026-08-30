import AppKit
import Metal
import MetalKit
import QuartzCore
import UIFoundation

extension AppleMusicLyrics {
    final class GradientBackgroundView: NSView {
        private let configuration = ArtworkGradientConfiguration()
        private let fallbackView = LayerBackedView()
        private let metalView: ArtworkGradientMetalView?
        private let paletteExtractionQueue = DispatchQueue(
            label: "ArtworkGradientPaletteExtraction",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )

        private var requestState = ArtworkGradientRequestState()
        private var artworkAbsenceWorkItem: DispatchWorkItem?
        private var windowOcclusionObserver: NSObjectProtocol?
        private var windowScreenObserver: NSObjectProtocol?
        private var accessibilityDisplayOptionsObserver: NSObjectProtocol?
        private var isPresentationVisible = false
        private var isWindowDragging = false
        private var isPerformingLiveResize = false

        override init(frame frameRect: NSRect) {
            let metalDevice = MTLCreateSystemDefaultDevice()
            if let metalDevice {
                self.metalView = try? ArtworkGradientMetalView(
                    frame: frameRect,
                    device: metalDevice,
                    configuration: configuration
                )
            } else {
                self.metalView = nil
            }

            super.init(frame: frameRect)
            configureViewHierarchy()
            observeAccessibilityDisplayOptions()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            artworkAbsenceWorkItem?.cancel()
            if let windowOcclusionObserver {
                NotificationCenter.default.removeObserver(windowOcclusionObserver)
            }
            if let windowScreenObserver {
                NotificationCenter.default.removeObserver(windowScreenObserver)
            }
            if let accessibilityDisplayOptionsObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(accessibilityDisplayOptionsObserver)
            }
        }

        override var isOpaque: Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            replaceWindowObservations()
            refreshPreferredFramesPerSecond()
            refreshRenderingState()
        }

        override func viewDidHide() {
            super.viewDidHide()
            refreshRenderingState()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            refreshRenderingState()
        }

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            isPerformingLiveResize = true
            refreshDrawableResizeSuspension()
            refreshRenderingState()
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            isPerformingLiveResize = false
            refreshDrawableResizeSuspension()
            refreshRenderingState()
        }

        func setPresentationVisible(_ isVisible: Bool) {
            guard isPresentationVisible != isVisible else { return }
            isPresentationVisible = isVisible
            refreshRenderingState()
        }

        func setWindowDragging(_ isDragging: Bool) {
            guard isWindowDragging != isDragging else { return }
            isWindowDragging = isDragging
            refreshDrawableResizeSuspension()
            refreshRenderingState()
        }

        func update(artwork: NSImage?, trackIdentity: String?) {
            let trackChanged = requestState.observeTrackIdentity(trackIdentity)
            if trackChanged {
                artworkAbsenceWorkItem?.cancel()
                artworkAbsenceWorkItem = nil
                if trackIdentity == nil {
                    applyFallbackPalette(animated: true)
                } else if artwork == nil {
                    scheduleArtworkAbsenceFallback()
                }
            }

            guard let artwork else { return }
            guard let generation = requestState.beginArtworkRequest() else { return }
            artworkAbsenceWorkItem?.cancel()
            artworkAbsenceWorkItem = nil

            guard let coreGraphicsImage = artwork.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ) else {
                applyFallbackPalette(animated: true)
                return
            }

            let configuration = configuration
            paletteExtractionQueue.async { [weak self] in
                let extractedColors = ArtworkGradientPaletteExtractor.dominantColors(
                    from: coreGraphicsImage,
                    configuration: configuration
                )
                DispatchQueue.main.async {
                    guard let self,
                          self.requestState.acceptsResult(generation: generation)
                    else {
                        return
                    }

                    let normalizedColors = ArtworkGradientPalette.normalized(
                        extractedColors ?? [],
                        colorCount: configuration.paletteColorCount
                    )
                    self.applyPalette(normalizedColors, animated: true)
                }
            }
        }

        private func configureViewHierarchy() {
            fallbackView.translatesAutoresizingMaskIntoConstraints = false
            fallbackView.backgroundColor = NSColor(
                red: 0.12,
                green: 0.15,
                blue: 0.2,
                alpha: 1
            )
            addSubview(fallbackView)

            var constraints = [
                fallbackView.topAnchor.constraint(equalTo: topAnchor),
                fallbackView.bottomAnchor.constraint(equalTo: bottomAnchor),
                fallbackView.leadingAnchor.constraint(equalTo: leadingAnchor),
                fallbackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]

            if let metalView {
                metalView.translatesAutoresizingMaskIntoConstraints = false
                addSubview(metalView)
                constraints.append(contentsOf: [
                    metalView.topAnchor.constraint(equalTo: topAnchor),
                    metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
                    metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
            }
            NSLayoutConstraint.activate(constraints)
        }

        private func replaceWindowObservations() {
            if let windowOcclusionObserver {
                NotificationCenter.default.removeObserver(windowOcclusionObserver)
                self.windowOcclusionObserver = nil
            }
            if let windowScreenObserver {
                NotificationCenter.default.removeObserver(windowScreenObserver)
                self.windowScreenObserver = nil
            }
            guard let window else { return }

            windowOcclusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refreshRenderingState()
            }

            windowScreenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refreshPreferredFramesPerSecond()
            }
        }

        private func observeAccessibilityDisplayOptions() {
            accessibilityDisplayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshRenderingState()
            }
        }

        private func refreshRenderingState() {
            guard let metalView else { return }

            let isWindowOccluded = !(window?.occlusionState.contains(.visible) ?? false)
            let shouldRenderContinuously = ArtworkGradientRenderingPolicy.shouldRenderContinuously(
                isPresentationVisible: isPresentationVisible,
                isAttachedToWindow: window != nil,
                isWindowVisible: window?.isVisible ?? false,
                isWindowOccluded: isWindowOccluded,
                isViewHidden: isHiddenOrHasHiddenAncestor,
                isWindowDragging: isWindowDragging,
                isLiveResizing: isPerformingLiveResize,
                shouldReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            metalView.setContinuousRenderingEnabled(shouldRenderContinuously)
            requestSingleFrameIfAppropriate()
        }

        private func refreshPreferredFramesPerSecond() {
            let preferredFramesPerSecond = ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: window?.screen?.maximumFramesPerSecond
            )
            metalView?.setPreferredFramesPerSecond(preferredFramesPerSecond)
        }

        private func refreshDrawableResizeSuspension() {
            metalView?.setDrawableResizingSuspended(
                isWindowDragging || isPerformingLiveResize
            )
        }

        private func requestSingleFrameIfAppropriate() {
            guard let metalView else { return }

            let isWindowOccluded = !(window?.occlusionState.contains(.visible) ?? false)
            let canRenderFrame = ArtworkGradientRenderingPolicy.canRenderFrame(
                isPresentationVisible: isPresentationVisible,
                isAttachedToWindow: window != nil,
                isWindowVisible: window?.isVisible ?? false,
                isWindowOccluded: isWindowOccluded,
                isViewHidden: isHiddenOrHasHiddenAncestor,
                isWindowDragging: isWindowDragging,
                isLiveResizing: isPerformingLiveResize
            )
            if canRenderFrame, metalView.isPaused {
                metalView.draw()
            }
        }

        private func applyPalette(_ colors: [ArtworkGradientColor], animated: Bool) {
            let shouldAnimate = animated
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            metalView?.setPalette(colors, animated: shouldAnimate)
            requestSingleFrameIfAppropriate()
        }

        private func applyFallbackPalette(animated: Bool) {
            let normalizedFallbackColors = ArtworkGradientPalette.normalized(
                ArtworkGradientPalette.fallback,
                colorCount: configuration.paletteColorCount
            )
            applyPalette(normalizedFallbackColors, animated: animated)
        }

        private func scheduleArtworkAbsenceFallback() {
            let generation = requestState.generation
            let artworkAbsenceWorkItem = DispatchWorkItem { [weak self] in
                guard let self,
                      requestState.acceptsResult(generation: generation),
                      !self.requestState.hasSubmittedArtwork
                else {
                    return
                }
                applyFallbackPalette(animated: true)
            }
            self.artworkAbsenceWorkItem = artworkAbsenceWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + configuration.artworkAbsenceFallbackDelay,
                execute: artworkAbsenceWorkItem
            )
        }
    }

    private enum ArtworkGradientMetalViewCreationError: Error {
        case unableToCreateCommandQueue
        case unavailableVertexFunction
        case unavailableFragmentFunction
    }

    private final class ArtworkGradientMetalView: MTKView, MTKViewDelegate {
        private let configuration: ArtworkGradientConfiguration
        private let commandQueue: MTLCommandQueue
        private let renderPipelineState: MTLRenderPipelineState
        private var animationClock = ArtworkGradientAnimationClock()
        private var transitionSourceColors: [SIMD4<Float>]
        private var transitionTargetColors: [SIMD4<Float>]
        private var transitionStartTime: TimeInterval = 0
        private var transitionDuration: TimeInterval = 0
        private var isDrawableResizingSuspended = false

        init(
            frame frameRect: NSRect,
            device metalDevice: MTLDevice,
            configuration: ArtworkGradientConfiguration
        ) throws {
            guard let commandQueue = metalDevice.makeCommandQueue() else {
                throw ArtworkGradientMetalViewCreationError.unableToCreateCommandQueue
            }
            let shaderLibrary = try metalDevice.makeDefaultLibrary(bundle: .module)
            guard let vertexFunction = shaderLibrary.makeFunction(
                name: "artworkGradientFullScreenVertex"
            ) else {
                throw ArtworkGradientMetalViewCreationError.unavailableVertexFunction
            }
            guard let fragmentFunction = shaderLibrary.makeFunction(
                name: "artworkGradientFragment"
            ) else {
                throw ArtworkGradientMetalViewCreationError.unavailableFragmentFunction
            }

            let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
            renderPipelineDescriptor.label = "Artwork Gradient Pipeline"
            renderPipelineDescriptor.vertexFunction = vertexFunction
            renderPipelineDescriptor.fragmentFunction = fragmentFunction
            renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

            self.configuration = configuration
            self.commandQueue = commandQueue
            self.renderPipelineState = try metalDevice.makeRenderPipelineState(
                descriptor: renderPipelineDescriptor
            )
            let fallbackColors = ArtworkGradientPalette.normalized(
                ArtworkGradientPalette.fallback,
                colorCount: configuration.paletteColorCount
            ).map(\.linearColorVector)
            self.transitionSourceColors = fallbackColors
            self.transitionTargetColors = fallbackColors

            super.init(frame: frameRect, device: metalDevice)

            delegate = self
            framebufferOnly = true
            colorPixelFormat = .bgra8Unorm_srgb
            depthStencilPixelFormat = .invalid
            sampleCount = 1
            preferredFramesPerSecond = ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
                screenMaximumFramesPerSecond: nil
            )
            enableSetNeedsDisplay = false
            autoResizeDrawable = false
            presentsWithTransaction = false
            clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1)
            colorspace = CGColorSpace(name: CGColorSpace.sRGB)
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

        func setContinuousRenderingEnabled(_ isEnabled: Bool) {
            guard isPaused == isEnabled else { return }

            let currentTimestamp = CACurrentMediaTime()
            animationClock.setPaused(!isEnabled, timestamp: currentTimestamp)
            isPaused = !isEnabled
            if isEnabled {
                draw()
            }
        }

        func setPreferredFramesPerSecond(_ framesPerSecond: Int) {
            guard preferredFramesPerSecond != framesPerSecond else { return }
            preferredFramesPerSecond = framesPerSecond
        }

        func setPalette(_ colors: [ArtworkGradientColor], animated: Bool) {
            let normalizedColors = ArtworkGradientPalette.normalized(
                colors,
                colorCount: configuration.paletteColorCount
            ).map(\.linearColorVector)
            let currentAnimationTime = animationClock.elapsedTime(at: CACurrentMediaTime())
            transitionSourceColors = interpolatedColors(at: currentAnimationTime)
            transitionTargetColors = normalizedColors
            transitionStartTime = currentAnimationTime
            transitionDuration = animated ? configuration.paletteTransitionDuration : 0
        }

        func setDrawableResizingSuspended(_ isSuspended: Bool) {
            guard isDrawableResizingSuspended != isSuspended else { return }
            isDrawableResizingSuspended = isSuspended
            if !isSuspended {
                updateDrawableSize()
            }
        }

        func draw(in view: MTKView) {
            guard let renderPassDescriptor = currentRenderPassDescriptor,
                  let drawable = currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(
                      descriptor: renderPassDescriptor
                  )
            else {
                return
            }

            let currentAnimationTime = animationClock.elapsedTime(at: CACurrentMediaTime())
            let paletteColors = interpolatedColors(at: currentAnimationTime)
            let aspectRatio = Float(drawableSize.width / max(1, drawableSize.height))
            var renderingParameters = SIMD4<Float>(
                Float(currentAnimationTime),
                configuration.darkOverlayOpacity,
                configuration.grainAmount,
                aspectRatio
            )

            renderCommandEncoder.label = "Artwork Gradient Render Encoder"
            renderCommandEncoder.setRenderPipelineState(renderPipelineState)
            paletteColors.withUnsafeBytes { paletteColorBytes in
                guard let baseAddress = paletteColorBytes.baseAddress else { return }
                renderCommandEncoder.setFragmentBytes(
                    baseAddress,
                    length: paletteColorBytes.count,
                    index: 0
                )
            }
            renderCommandEncoder.setFragmentBytes(
                &renderingParameters,
                length: MemoryLayout<SIMD4<Float>>.stride,
                index: 1
            )
            renderCommandEncoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 3
            )
            renderCommandEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        private func updateDrawableSize() {
            guard !isDrawableResizingSuspended else { return }

            let nativeBackingBounds = convertToBacking(bounds)
            let updatedDrawableSize = configuration.drawablePixelSize(
                forNativeBackingSize: nativeBackingBounds.size
            )
            guard drawableSize != updatedDrawableSize else { return }
            drawableSize = updatedDrawableSize
            if isPaused {
                draw()
            }
        }

        private func interpolatedColors(at animationTime: TimeInterval) -> [SIMD4<Float>] {
            guard transitionDuration > 0 else { return transitionTargetColors }

            let transitionProgress = Float(min(
                1,
                max(0, (animationTime - transitionStartTime) / transitionDuration)
            ))
            return transitionSourceColors.indices.map { colorIndex in
                let sourceColor = transitionSourceColors[colorIndex]
                let targetColor = transitionTargetColors[colorIndex]
                return sourceColor + (targetColor - sourceColor) * transitionProgress
            }
        }
    }
}
