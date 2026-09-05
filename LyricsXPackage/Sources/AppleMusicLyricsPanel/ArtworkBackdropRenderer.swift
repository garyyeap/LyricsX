import Metal
import MetalKit
import MetalPerformanceShaders
import OSToolbox
import QuartzCore

extension AppleMusicLyrics {
    struct ArtworkBackdropTransitionState {
        private(set) var sourceTextureState: ArtworkBackdropTextureState
        private(set) var destinationTextureState: ArtworkBackdropTextureState
        private var pendingTextureState: ArtworkBackdropTextureState?
        private var transitionStartTime: TimeInterval = 0
        private var transitionDuration: TimeInterval = 0

        init(initialTextureState: ArtworkBackdropTextureState) {
            self.sourceTextureState = initialTextureState
            self.destinationTextureState = initialTextureState
        }

        mutating func enqueue(
            _ textureState: ArtworkBackdropTextureState,
            animated: Bool,
            animationTime: TimeInterval,
            transitionDuration: TimeInterval
        ) {
            advanceIfNeeded(
                animationTime: animationTime,
                transitionDuration: transitionDuration
            )
            if animated, self.transitionDuration > 0 {
                pendingTextureState = textureState
            } else if animated {
                sourceTextureState = destinationTextureState
                destinationTextureState = textureState
                transitionStartTime = animationTime
                self.transitionDuration = transitionDuration
            } else {
                sourceTextureState = textureState
                destinationTextureState = textureState
                pendingTextureState = nil
                transitionStartTime = animationTime
                self.transitionDuration = 0
            }
        }

        mutating func advanceIfNeeded(
            animationTime: TimeInterval,
            transitionDuration: TimeInterval
        ) {
            guard self.transitionDuration > 0,
                  progress(at: animationTime) >= 1
            else {
                return
            }

            sourceTextureState = destinationTextureState
            self.transitionDuration = 0
            if let pendingTextureState {
                self.pendingTextureState = nil
                destinationTextureState = pendingTextureState
                transitionStartTime = animationTime
                self.transitionDuration = transitionDuration
            }
        }

        func progress(at animationTime: TimeInterval) -> Float {
            guard transitionDuration > 0 else { return 1 }
            return Float(min(
                1,
                max(0, (animationTime - transitionStartTime) / transitionDuration)
            ))
        }

        func averageLuminosity(at animationTime: TimeInterval) -> Float {
            let transitionProgress = progress(at: animationTime)
            return sourceTextureState.averageLuminosity
                + (destinationTextureState.averageLuminosity
                    - sourceTextureState.averageLuminosity) * transitionProgress
        }
    }

    enum ArtworkBackdropRendererCreationError: Error {
        case metalPerformanceShadersUnavailable
        case unableToCreateCommandQueue
    }

    struct ArtworkBackdropFrameTarget {
        let renderPassDescriptor: MTLRenderPassDescriptor
        let drawable: CAMetalDrawable
        let acquisitionDuration: TimeInterval
    }

    struct ArtworkBackdropFrameTimingContext {
        let frameTimestamp: TimeInterval
        let frameCompletionTimestamp: TimeInterval
        let expectedFrameDuration: TimeInterval
        let renderPassAcquisitionDuration: TimeInterval
        let commandBufferCreationDuration: TimeInterval
        let commandEncodingDuration: TimeInterval
        let commandSubmissionDuration: TimeInterval
        let preferredFramesPerSecond: Int
        let drawableSize: CGSize
    }

    @Loggable(
        isEnabled: false,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel",
        category: "GradientFrame"
    )
    @Signpostable(
        isEnabled: false,
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel",
        category: "GradientFrame"
    )
    final class ArtworkBackdropRenderer {
        let drawablePixelFormat: MTLPixelFormat

        private let configuration: ArtworkGradientConfiguration
        private let metalDevice: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let pipeline: ArtworkBackdropPipeline

        private var transitionState: ArtworkBackdropTransitionState
        private var animationClock = ArtworkGradientAnimationClock()
        private var compositionTexture: MTLTexture?
        private var blurredTexture: MTLTexture?
        private var gaussianBlur: MPSImageGaussianBlur?
        private var frameTimingAccumulator = FrameTimingAccumulator()
        private var frameStageTimingAccumulator = GradientFrameStageTimingAccumulator()
        private var lastSlowFrameLogTimestamp: TimeInterval = -.infinity

        init(
            device metalDevice: MTLDevice,
            configuration: ArtworkGradientConfiguration,
            shaderLibrary: MTLLibrary? = nil
        ) throws {
            guard MPSSupportsMTLDevice(metalDevice) else {
                throw ArtworkBackdropRendererCreationError
                    .metalPerformanceShadersUnavailable
            }
            guard let commandQueue = metalDevice.makeCommandQueue() else {
                throw ArtworkBackdropRendererCreationError.unableToCreateCommandQueue
            }
            let pipeline = try ArtworkBackdropPipeline(
                device: metalDevice,
                configuration: configuration,
                shaderLibrary: shaderLibrary
            )

            self.configuration = configuration
            self.metalDevice = metalDevice
            self.commandQueue = commandQueue
            self.pipeline = pipeline
            self.drawablePixelFormat = pipeline.drawablePixelFormat
            self.transitionState = ArtworkBackdropTransitionState(
                initialTextureState: pipeline.fallbackTextureState
            )
        }

        func setRenderingState(
            isFrameRenderingAllowed: Bool,
            isContinuousRenderingEnabled: Bool,
            preferredFramesPerSecond: Int
        ) {
            animationClock.setPaused(
                !isContinuousRenderingEnabled,
                timestamp: CACurrentMediaTime()
            )
            resetFrameDiagnostics()
            #log(
                .info,
                """
                Gradient rendering changed allowed=\(isFrameRenderingAllowed, privacy: .public) \
                continuous=\(isContinuousRenderingEnabled, privacy: .public) \
                preferredFramesPerSecond=\(preferredFramesPerSecond, privacy: .public) \
                mainThread=\(Thread.isMainThread, privacy: .public)
                """
            )
            #signpost(
                .event,
                "GradientRenderingChanged",
                """
                allowed=\(isFrameRenderingAllowed, privacy: .public) \
                continuous=\(isContinuousRenderingEnabled, privacy: .public)
                """
            )
        }

        func setPreferredFramesPerSecond(
            previousFramesPerSecond: Int,
            currentFramesPerSecond: Int
        ) {
            resetFrameDiagnostics()
            #log(
                .info,
                """
                Gradient preferred frame rate changed \
                previous=\(previousFramesPerSecond, privacy: .public) \
                current=\(currentFramesPerSecond, privacy: .public)
                """
            )
            #signpost(
                .event,
                "GradientFrameRateChanged",
                """
                previous=\(previousFramesPerSecond, privacy: .public) \
                current=\(currentFramesPerSecond, privacy: .public)
                """
            )
        }

        func enqueueArtworkTexture(
            _ artworkTexture: MTLTexture,
            averageLuminosity: Float,
            animated: Bool
        ) {
            enqueueTextureState(
                ArtworkBackdropTextureState(
                    texture: artworkTexture,
                    averageLuminosity: min(1, max(0, averageLuminosity))
                ),
                animated: animated
            )
        }

        func enqueueFallbackTexture(animated: Bool) {
            enqueueTextureState(
                pipeline.fallbackTextureState,
                animated: animated
            )
        }

        func drawableSizeWillChange(_ drawableSize: CGSize) {
            compositionTexture = nil
            blurredTexture = nil
            gaussianBlur = nil
            #signpost(
                .event,
                "GradientDrawableSizeChanged",
                """
                width=\(drawableSize.width, privacy: .public) \
                height=\(drawableSize.height, privacy: .public)
                """
            )
        }
    }
}

extension AppleMusicLyrics.ArtworkBackdropRenderer {
    func draw(in metalView: MTKView) {
        autoreleasepool {
            if AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
                .detailedFrameSignpostingIsEnabled {
                #signpostInterval("GradientFrameEncode") {
                    drawFrame(in: metalView)
                }
            } else {
                drawFrame(in: metalView)
            }
        }
    }

    private func drawFrame(in metalView: MTKView) {
        let frameTimestamp = CACurrentMediaTime()
        let expectedFrameDuration = 1
            / TimeInterval(max(1, metalView.preferredFramesPerSecond))
        let animationTime = animationClock.elapsedTime(at: frameTimestamp)
        transitionState.advanceIfNeeded(
            animationTime: animationTime,
            transitionDuration: configuration.artworkTransitionDuration
        )
        guard rebuildOffscreenResourcesIfNeeded(drawableSize: metalView.drawableSize),
              let compositionTexture,
              let blurredTexture,
              let gaussianBlur
        else {
            return
        }

        let commandBufferCreationStartTimestamp = CACurrentMediaTime()
        let commandBuffer = makeCommandBuffer()
        let commandBufferCreationDuration = CACurrentMediaTime()
            - commandBufferCreationStartTimestamp
        guard let commandBuffer else { return }
        configureErrorReporting(for: commandBuffer)

        let offscreenEncodingStartTimestamp = CACurrentMediaTime()
        guard encodeOffscreenFrame(
            commandBuffer: commandBuffer,
            compositionTexture: compositionTexture,
            blurredTexture: blurredTexture,
            gaussianBlur: gaussianBlur,
            animationTime: animationTime
        ) else {
            return
        }
        let offscreenEncodingDuration = CACurrentMediaTime()
            - offscreenEncodingStartTimestamp

        guard let frameTarget = acquireFrameTarget(from: metalView) else {
            return
        }

        let finalEncodingStartTimestamp = CACurrentMediaTime()
        guard encodeFinalFrame(
            commandBuffer: commandBuffer,
            renderPassDescriptor: frameTarget.renderPassDescriptor,
            blurredTexture: blurredTexture,
            animationTime: animationTime
        ) else {
            return
        }
        let finalEncodingDuration = CACurrentMediaTime()
            - finalEncodingStartTimestamp
        let commandEncodingDuration = offscreenEncodingDuration
            + finalEncodingDuration

        let commandSubmissionStartTimestamp = CACurrentMediaTime()
        submit(
            commandBuffer: commandBuffer,
            drawable: frameTarget.drawable
        )
        let frameCompletionTimestamp = CACurrentMediaTime()
        let commandSubmissionDuration = frameCompletionTimestamp
            - commandSubmissionStartTimestamp
        recordFrame(AppleMusicLyrics.ArtworkBackdropFrameTimingContext(
            frameTimestamp: frameTimestamp,
            frameCompletionTimestamp: frameCompletionTimestamp,
            expectedFrameDuration: expectedFrameDuration,
            renderPassAcquisitionDuration: frameTarget.acquisitionDuration,
            commandBufferCreationDuration: commandBufferCreationDuration,
            commandEncodingDuration: commandEncodingDuration,
            commandSubmissionDuration: commandSubmissionDuration,
            preferredFramesPerSecond: metalView.preferredFramesPerSecond,
            drawableSize: metalView.drawableSize
        ))
    }

    private func makeCommandBuffer() -> MTLCommandBuffer? {
        if AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
            .detailedFrameSignpostingIsEnabled {
            return #signpostInterval("GradientCommandBufferCreation") {
                commandQueue.makeCommandBuffer()
            }
        }
        return commandQueue.makeCommandBuffer()
    }

    private func submit(
        commandBuffer: MTLCommandBuffer,
        drawable: CAMetalDrawable
    ) {
        if AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
            .detailedFrameSignpostingIsEnabled {
            #signpostInterval("GradientCommandSubmission") {
                commit(commandBuffer: commandBuffer, drawable: drawable)
            }
        } else {
            commit(commandBuffer: commandBuffer, drawable: drawable)
        }
    }

    private func commit(
        commandBuffer: MTLCommandBuffer,
        drawable: CAMetalDrawable
    ) {
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

extension AppleMusicLyrics.ArtworkBackdropRenderer {
    fileprivate func enqueueTextureState(
        _ textureState: AppleMusicLyrics.ArtworkBackdropTextureState,
        animated: Bool
    ) {
        let animationTime = animationClock.elapsedTime(at: CACurrentMediaTime())
        transitionState.enqueue(
            textureState,
            animated: animated,
            animationTime: animationTime,
            transitionDuration: configuration.artworkTransitionDuration
        )
    }

    fileprivate func acquireFrameTarget(from metalView: MTKView) -> AppleMusicLyrics.ArtworkBackdropFrameTarget? {
        let acquisitionStartTimestamp = CACurrentMediaTime()
        let renderPassDescriptor: MTLRenderPassDescriptor?
        if AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
            .detailedFrameSignpostingIsEnabled {
            renderPassDescriptor = #signpostInterval(
                "GradientRenderPassAcquisition"
            ) {
                metalView.currentRenderPassDescriptor
            }
        } else {
            renderPassDescriptor = metalView.currentRenderPassDescriptor
        }
        let acquisitionDuration = CACurrentMediaTime()
            - acquisitionStartTimestamp
        guard let renderPassDescriptor,
              let drawable = metalView.currentDrawable
        else {
            return nil
        }
        return AppleMusicLyrics.ArtworkBackdropFrameTarget(
            renderPassDescriptor: renderPassDescriptor,
            drawable: drawable,
            acquisitionDuration: acquisitionDuration
        )
    }

    fileprivate func encodeOffscreenFrame(
        commandBuffer: MTLCommandBuffer,
        compositionTexture: MTLTexture,
        blurredTexture: MTLTexture,
        gaussianBlur: MPSImageGaussianBlur,
        animationTime: TimeInterval
    ) -> Bool {
        if AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
            .detailedFrameSignpostingIsEnabled {
            return #signpostInterval("GradientOffscreenEncoding") {
                encodeOffscreenCommands(
                    commandBuffer: commandBuffer,
                    compositionTexture: compositionTexture,
                    blurredTexture: blurredTexture,
                    gaussianBlur: gaussianBlur,
                    animationTime: animationTime
                )
            }
        }
        return encodeOffscreenCommands(
            commandBuffer: commandBuffer,
            compositionTexture: compositionTexture,
            blurredTexture: blurredTexture,
            gaussianBlur: gaussianBlur,
            animationTime: animationTime
        )
    }

    fileprivate func encodeOffscreenCommands(
        commandBuffer: MTLCommandBuffer,
        compositionTexture: MTLTexture,
        blurredTexture: MTLTexture,
        gaussianBlur: MPSImageGaussianBlur,
        animationTime: TimeInterval
    ) -> Bool {
        let transitionProgress = transitionState.progress(at: animationTime)
        guard pipeline.encodeComposition(
            commandBuffer: commandBuffer,
            destinationTexture: compositionTexture,
            sourceTextureState: transitionState.sourceTextureState,
            destinationTextureState: transitionState.destinationTextureState,
            transitionProgress: transitionProgress,
            animationTime: animationTime
        ) else {
            return false
        }
        gaussianBlur.encode(
            commandBuffer: commandBuffer,
            sourceTexture: compositionTexture,
            destinationTexture: blurredTexture
        )
        return true
    }

    fileprivate func encodeFinalFrame(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        blurredTexture: MTLTexture,
        animationTime: TimeInterval
    ) -> Bool {
        if AppleMusicLyrics.FramePerformanceDiagnosticsPolicy
            .detailedFrameSignpostingIsEnabled {
            return #signpostInterval("GradientFinalEncoding") {
                encodeFinalCommands(
                    commandBuffer: commandBuffer,
                    renderPassDescriptor: renderPassDescriptor,
                    blurredTexture: blurredTexture,
                    animationTime: animationTime
                )
            }
        }
        return encodeFinalCommands(
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor,
            blurredTexture: blurredTexture,
            animationTime: animationTime
        )
    }

    fileprivate func encodeFinalCommands(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        blurredTexture: MTLTexture,
        animationTime: TimeInterval
    ) -> Bool {
        pipeline.encodeFinalBackdrop(
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor,
            blurredTexture: blurredTexture,
            animationTime: animationTime,
            averageLuminosity: transitionState.averageLuminosity(
                at: animationTime
            ),
            configuration: configuration
        )
    }

    fileprivate func rebuildOffscreenResourcesIfNeeded(drawableSize: CGSize) -> Bool {
        let textureWidth = max(1, Int(drawableSize.width.rounded()))
        let textureHeight = max(1, Int(drawableSize.height.rounded()))
        if compositionTexture?.width == textureWidth,
           compositionTexture?.height == textureHeight,
           blurredTexture?.width == textureWidth,
           blurredTexture?.height == textureHeight,
           gaussianBlur != nil {
            return true
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pipeline.drawablePixelFormat,
            width: textureWidth,
            height: textureHeight,
            mipmapped: false
        )
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        guard let compositionTexture = metalDevice.makeTexture(
            descriptor: textureDescriptor
        ), let blurredTexture = metalDevice.makeTexture(
            descriptor: textureDescriptor
        ) else {
            return false
        }
        compositionTexture.label = "Artwork Backdrop Composition Texture"
        blurredTexture.label = "Artwork Backdrop Blurred Texture"

        let textureDiagonal = hypot(Float(textureWidth), Float(textureHeight))
        let blurSigma = max(
            1,
            floor(textureDiagonal * configuration.blurSigmaFraction)
        )
        let gaussianBlur = MPSImageGaussianBlur(
            device: metalDevice,
            sigma: blurSigma
        )
        gaussianBlur.options = AppleMusicLyrics.ArtworkBackdropRenderingProfile
            .gaussianBlurOptions
        gaussianBlur.edgeMode = AppleMusicLyrics.ArtworkBackdropRenderingProfile
            .gaussianBlurEdgeMode

        self.compositionTexture = compositionTexture
        self.blurredTexture = blurredTexture
        self.gaussianBlur = gaussianBlur
        let drawablePixelFormatRawValue = pipeline.drawablePixelFormat.rawValue
        #log(
            .info,
            """
            Gradient offscreen textures rebuilt width=\(textureWidth, privacy: .public) \
            height=\(textureHeight, privacy: .public) \
            blurSigma=\(blurSigma, privacy: .public) \
            pixelFormat=\(drawablePixelFormatRawValue, privacy: .public)
            """
        )
        #signpost(
            .event,
            "GradientOffscreenTexturesRebuilt",
            """
            width=\(textureWidth, privacy: .public) \
            height=\(textureHeight, privacy: .public)
            """
        )
        return true
    }

    fileprivate func configureErrorReporting(for commandBuffer: MTLCommandBuffer) {
        commandBuffer.label = "Artwork Backdrop Command Buffer"
        commandBuffer.addCompletedHandler { completedCommandBuffer in
            guard completedCommandBuffer.status == .error else { return }
            let errorDescription = completedCommandBuffer.error?.localizedDescription
                ?? "unknown"
            #log(
                .error,
                """
                Gradient command buffer failed \
                status=\(completedCommandBuffer.status.rawValue, privacy: .public) \
                error=\(errorDescription, privacy: .public)
                """
            )
            #signpost(
                .event,
                "GradientCommandBufferFailed",
                "status=\(completedCommandBuffer.status.rawValue, privacy: .public)"
            )
        }
    }
}

extension AppleMusicLyrics.ArtworkBackdropRenderer {
    fileprivate func recordFrame(
        _ timingContext: AppleMusicLyrics.ArtworkBackdropFrameTimingContext
    ) {
        let stageTimingSample = AppleMusicLyrics.GradientFrameStageTimingSample(
            renderPassAcquisitionDuration: timingContext.renderPassAcquisitionDuration,
            drawableAcquisitionDuration: 0,
            commandBufferCreationDuration: timingContext.commandBufferCreationDuration,
            renderCommandEncoderCreationDuration: 0,
            commandEncodingDuration: timingContext.commandEncodingDuration,
            commandSubmissionDuration: timingContext.commandSubmissionDuration,
            totalDuration: timingContext.frameCompletionTimestamp
                - timingContext.frameTimestamp,
            wasOnMainThread: Thread.isMainThread
        )
        frameStageTimingAccumulator.record(
            stageTimingSample,
            expectedFrameDuration: timingContext.expectedFrameDuration
        )
        recordSlowFrameIfNeeded(
            stageTimingSample,
            expectedFrameDuration: timingContext.expectedFrameDuration,
            frameCompletionTimestamp: timingContext.frameCompletionTimestamp
        )
        recordFrameCadence(
            frameTimestamp: timingContext.frameTimestamp,
            expectedFrameDuration: timingContext.expectedFrameDuration,
            preferredFramesPerSecond: timingContext.preferredFramesPerSecond,
            drawableSize: timingContext.drawableSize
        )
    }

    fileprivate func recordFrameCadence(
        frameTimestamp: TimeInterval,
        expectedFrameDuration: TimeInterval,
        preferredFramesPerSecond: Int,
        drawableSize: CGSize
    ) {
        guard let report = frameTimingAccumulator.record(
            sourceTimestamp: frameTimestamp,
            arrivalTimestamp: frameTimestamp,
            targetTimestamp: frameTimestamp,
            expectedFrameDuration: expectedFrameDuration
        ) else {
            return
        }

        let stageTimingReport = frameStageTimingAccumulator.takeReport()
        #log(
            .info,
            """
            Gradient cadence \
            preferredFramesPerSecond=\(preferredFramesPerSecond, privacy: .public) \
            measuredFramesPerSecond=\(report.arrivalFramesPerSecond, privacy: .public) \
            missedFrames=\(report.missedArrivalFrameCount, privacy: .public) \
            maximumFrameGapMilliseconds=\(report.maximumArrivalGapMilliseconds, privacy: .public) \
            drawableWidth=\(drawableSize.width, privacy: .public) \
            drawableHeight=\(drawableSize.height, privacy: .public)
            """
        )
        #log(
            .info,
            """
            Gradient stages samples=\(stageTimingReport?.sampledFrameCount ?? 0, privacy: .public) \
            mainThreadFrames=\(stageTimingReport?.mainThreadFrameCount ?? 0, privacy: .public) \
            frameBudgetOverruns=\(stageTimingReport?.frameBudgetOverrunCount ?? 0, privacy: .public) \
            averageRenderPassMilliseconds=\(stageTimingReport?.averageRenderPassAcquisitionMilliseconds ?? 0, privacy: .public) \
            maximumRenderPassMilliseconds=\(stageTimingReport?.maximumRenderPassAcquisitionMilliseconds ?? 0, privacy: .public) \
            averageEncodingMilliseconds=\(stageTimingReport?.averageCommandEncodingMilliseconds ?? 0, privacy: .public) \
            maximumEncodingMilliseconds=\(stageTimingReport?.maximumCommandEncodingMilliseconds ?? 0, privacy: .public) \
            averageSubmissionMilliseconds=\(stageTimingReport?.averageCommandSubmissionMilliseconds ?? 0, privacy: .public) \
            maximumSubmissionMilliseconds=\(stageTimingReport?.maximumCommandSubmissionMilliseconds ?? 0, privacy: .public) \
            averageTotalMilliseconds=\(stageTimingReport?.averageTotalDurationMilliseconds ?? 0, privacy: .public) \
            maximumTotalMilliseconds=\(stageTimingReport?.maximumTotalDurationMilliseconds ?? 0, privacy: .public)
            """
        )
    }

    fileprivate func resetFrameDiagnostics() {
        frameTimingAccumulator = AppleMusicLyrics.FrameTimingAccumulator()
        frameStageTimingAccumulator = AppleMusicLyrics.GradientFrameStageTimingAccumulator()
        lastSlowFrameLogTimestamp = -.infinity
    }

    fileprivate func recordSlowFrameIfNeeded(
        _ sample: AppleMusicLyrics.GradientFrameStageTimingSample,
        expectedFrameDuration: TimeInterval,
        frameCompletionTimestamp: TimeInterval
    ) {
        guard sample.totalDuration > expectedFrameDuration,
              frameCompletionTimestamp - lastSlowFrameLogTimestamp >= 1
        else {
            return
        }

        lastSlowFrameLogTimestamp = frameCompletionTimestamp
        #log(
            .info,
            """
            Gradient slow frame \
            totalMilliseconds=\(sample.totalDuration * 1_000, privacy: .public) \
            budgetMilliseconds=\(expectedFrameDuration * 1_000, privacy: .public) \
            renderPassMilliseconds=\(sample.renderPassAcquisitionDuration * 1_000, privacy: .public) \
            encodingMilliseconds=\(sample.commandEncodingDuration * 1_000, privacy: .public) \
            submissionMilliseconds=\(sample.commandSubmissionDuration * 1_000, privacy: .public) \
            mainThread=\(sample.wasOnMainThread, privacy: .public)
            """
        )
        #signpost(
            .event,
            "GradientSlowFrame",
            """
            totalMilliseconds=\(sample.totalDuration * 1_000, privacy: .public) \
            renderPassMilliseconds=\(sample.renderPassAcquisitionDuration * 1_000, privacy: .public) \
            encodingMilliseconds=\(sample.commandEncodingDuration * 1_000, privacy: .public)
            """
        )
    }
}
