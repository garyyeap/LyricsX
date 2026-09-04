import AppKit
import MetalKit
import OSToolbox
import UIFoundation

extension AppleMusicLyrics {
    @Loggable(
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel",
        category: "GradientRenderer"
    )
    @Signpostable(
        subsystem: "com.JH.LyricsX.AppleMusicLyricsPanel",
        category: "GradientRenderer"
    )
    final class GradientBackgroundView: NSView {
        private let configuration = ArtworkGradientConfiguration()
        private let fallbackView = LayerBackedView()
        private let metalView: ArtworkGradientMetalView?
        private let textureLoader: MTKTextureLoader?
        private let artworkPreparationQueue = DispatchQueue(
            label: "ArtworkBackdropPreparation",
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
                self.textureLoader = MTKTextureLoader(device: metalDevice)
                self.metalView = try? ArtworkGradientMetalView(
                    frame: frameRect,
                    device: metalDevice,
                    configuration: configuration
                )
            } else {
                self.textureLoader = nil
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
            removeWindowObservations()
            if let accessibilityDisplayOptionsObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(
                    accessibilityDisplayOptionsObserver
                )
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
            handleTrackChange(artwork: artwork, trackIdentity: trackIdentity)
            guard let artwork,
                  let generation = requestState.beginArtworkRequest()
            else {
                return
            }

            artworkAbsenceWorkItem?.cancel()
            artworkAbsenceWorkItem = nil
            guard let sourceImage = artwork.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ), let textureLoader else {
                applyFallbackArtwork(animated: true)
                return
            }
            prepareArtwork(
                sourceImage,
                generation: generation,
                textureLoader: textureLoader
            )
        }
    }
}

extension AppleMusicLyrics.GradientBackgroundView {
    fileprivate func handleTrackChange(artwork: NSImage?, trackIdentity: String?) {
        guard requestState.observeTrackIdentity(trackIdentity) else { return }

        let hasTrackIdentity = trackIdentity != nil
        let hasArtwork = artwork != nil
        #log(
            .info,
            """
            Gradient track changed hasIdentity=\(hasTrackIdentity, privacy: .public) \
            hasArtwork=\(hasArtwork, privacy: .public)
            """
        )
        #signpost(
            .event,
            "GradientTrackChanged",
            "hasArtwork=\(hasArtwork, privacy: .public)"
        )

        artworkAbsenceWorkItem?.cancel()
        artworkAbsenceWorkItem = nil
        if trackIdentity == nil {
            applyFallbackArtwork(animated: true)
        } else if artwork == nil {
            scheduleArtworkAbsenceFallback()
        }
    }

    fileprivate func prepareArtwork(
        _ sourceImage: CGImage,
        generation: UInt64,
        textureLoader: MTKTextureLoader
    ) {
        let maximumArtworkDimension = configuration.maximumArtworkDimension
        let preparationInterval = #signpost(
            .begin,
            "ArtworkBackdropPreparation",
            "generation=\(generation, privacy: .public)"
        )
        artworkPreparationQueue.async { [weak self] in
            let preparedArtwork = AppleMusicLyrics.ArtworkBackdropImageProcessor.prepare(
                sourceImage,
                maximumDimension: maximumArtworkDimension
            )
            let preparedTexture = preparedArtwork.flatMap { preparedArtwork in
                try? textureLoader.newTexture(
                    cgImage: preparedArtwork.image,
                    options: Self.artworkTextureLoadingOptions
                )
            }
            let preparationSucceeded = preparedTexture != nil
            #signpost(
                .end,
                preparationInterval,
                "success=\(preparationSucceeded, privacy: .public)"
            )

            DispatchQueue.main.async {
                self?.applyPreparedArtwork(
                    preparedArtwork,
                    texture: preparedTexture,
                    generation: generation
                )
            }
        }
    }

    fileprivate func applyPreparedArtwork(
        _ preparedArtwork: AppleMusicLyrics.PreparedArtworkBackdrop?,
        texture: MTLTexture?,
        generation: UInt64
    ) {
        guard requestState.acceptsResult(generation: generation) else { return }
        guard let preparedArtwork,
              let texture
        else {
            #log(
                .error,
                "Artwork backdrop preparation failed generation=\(generation, privacy: .public)"
            )
            applyFallbackArtwork(animated: true)
            return
        }

        let textureWidth = texture.width
        let textureHeight = texture.height
        let averageLuminosity = preparedArtwork.averageLuminosity
        #log(
            .info,
            """
            Artwork backdrop applied generation=\(generation, privacy: .public) \
            width=\(textureWidth, privacy: .public) \
            height=\(textureHeight, privacy: .public) \
            luminosity=\(averageLuminosity, privacy: .public)
            """
        )
        #signpost(
            .event,
            "ArtworkBackdropApplied",
            "width=\(textureWidth, privacy: .public) height=\(textureHeight, privacy: .public)"
        )
        metalView?.setArtworkTexture(
            texture,
            averageLuminosity: averageLuminosity,
            animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        requestSingleFrameIfAppropriate()
    }

    fileprivate func configureViewHierarchy() {
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

    fileprivate func removeWindowObservations() {
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
            self.windowOcclusionObserver = nil
        }
        if let windowScreenObserver {
            NotificationCenter.default.removeObserver(windowScreenObserver)
            self.windowScreenObserver = nil
        }
    }

    fileprivate func replaceWindowObservations() {
        removeWindowObservations()
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

    fileprivate func observeAccessibilityDisplayOptions() {
        accessibilityDisplayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRenderingState()
        }
    }

    fileprivate func refreshRenderingState() {
        guard let metalView else { return }

        let isPresentationVisible = self.isPresentationVisible
        let isWindowDragging = self.isWindowDragging
        let isPerformingLiveResize = self.isPerformingLiveResize
        let isWindowOccluded = !(window?.occlusionState.contains(.visible) ?? false)
        let isAttachedToWindow = window != nil
        let isWindowVisible = window?.isVisible ?? false
        let isViewHidden = isHiddenOrHasHiddenAncestor
        let shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let canRenderFrame = AppleMusicLyrics.ArtworkGradientRenderingPolicy.canRenderFrame(
            isPresentationVisible: isPresentationVisible,
            isAttachedToWindow: isAttachedToWindow,
            isWindowVisible: isWindowVisible,
            isWindowOccluded: isWindowOccluded,
            isViewHidden: isViewHidden,
            isWindowDragging: isWindowDragging,
            isLiveResizing: isPerformingLiveResize
        )
        let shouldRenderContinuously = AppleMusicLyrics.ArtworkGradientRenderingPolicy.shouldRenderContinuously(
            isPresentationVisible: isPresentationVisible,
            isAttachedToWindow: isAttachedToWindow,
            isWindowVisible: isWindowVisible,
            isWindowOccluded: isWindowOccluded,
            isViewHidden: isViewHidden,
            isWindowDragging: isWindowDragging,
            isLiveResizing: isPerformingLiveResize,
            shouldReduceMotion: shouldReduceMotion
        )

        #log(
            .info,
            """
            Gradient rendering state continuous=\(shouldRenderContinuously, privacy: .public) \
            allowed=\(canRenderFrame, privacy: .public) \
            presentationVisible=\(isPresentationVisible, privacy: .public) \
            windowVisible=\(isWindowVisible, privacy: .public) \
            occluded=\(isWindowOccluded, privacy: .public) \
            windowDragging=\(isWindowDragging, privacy: .public) \
            liveResizing=\(isPerformingLiveResize, privacy: .public) \
            reduceMotion=\(shouldReduceMotion, privacy: .public)
            """
        )
        metalView.setRenderingState(
            isFrameRenderingAllowed: canRenderFrame,
            isContinuousRenderingEnabled: shouldRenderContinuously
        )
        requestSingleFrameIfAppropriate()
    }

    fileprivate func refreshPreferredFramesPerSecond() {
        let preferredFramesPerSecond = AppleMusicLyrics.ArtworkGradientRenderingPolicy.preferredFramesPerSecond(
            screenMaximumFramesPerSecond: window?.screen?.maximumFramesPerSecond
        )
        metalView?.setPreferredFramesPerSecond(preferredFramesPerSecond)
    }

    fileprivate func refreshDrawableResizeSuspension() {
        metalView?.setDrawableResizingSuspended(
            isWindowDragging || isPerformingLiveResize
        )
    }

    fileprivate func requestSingleFrameIfAppropriate() {
        guard let metalView else { return }
        let isWindowOccluded = !(window?.occlusionState.contains(.visible) ?? false)
        let canRenderFrame = AppleMusicLyrics.ArtworkGradientRenderingPolicy.canRenderFrame(
            isPresentationVisible: isPresentationVisible,
            isAttachedToWindow: window != nil,
            isWindowVisible: window?.isVisible ?? false,
            isWindowOccluded: isWindowOccluded,
            isViewHidden: isHiddenOrHasHiddenAncestor,
            isWindowDragging: isWindowDragging,
            isLiveResizing: isPerformingLiveResize
        )
        if canRenderFrame {
            metalView.requestSingleFrame()
        }
    }

    fileprivate func applyFallbackArtwork(animated: Bool) {
        metalView?.setFallbackArtwork(
            animated: animated
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        requestSingleFrameIfAppropriate()
    }

    fileprivate func scheduleArtworkAbsenceFallback() {
        let generation = requestState.generation
        let artworkAbsenceWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.requestState.acceptsResult(generation: generation),
                  !self.requestState.hasSubmittedArtwork
            else {
                return
            }
            self.applyFallbackArtwork(animated: true)
        }
        self.artworkAbsenceWorkItem = artworkAbsenceWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + configuration.artworkAbsenceFallbackDelay,
            execute: artworkAbsenceWorkItem
        )
    }

    fileprivate static var artworkTextureLoadingOptions: [MTKTextureLoader.Option: Any] {
        [
            .SRGB: true,
            .generateMipmaps: true,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ]
    }
}
