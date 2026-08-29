import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

@Suite(.serialized)
@MainActor
struct LineTransitionProbes {
    private static let selectedLineBaselineViewportFraction: CGFloat = 0.4

    private static func makeLyrics() -> Lyrics? {
        let body = (0 ..< 12)
            .map { lineIndex in String(format: "[00:%05.2f]probe line number %d", Double(lineIndex) * 4, lineIndex) }
            .joined(separator: "\n")
        return Lyrics(body)
    }

    private static func makeMountedContainer() -> (AppleMusicLyrics.SyncedLyricsContainerView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        let container = AppleMusicLyrics.SyncedLyricsContainerView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        return (container, window)
    }

    private static func scrollView(of container: AppleMusicLyrics.SyncedLyricsContainerView) throws -> NSScrollView {
        try #require(
            container.subviews.compactMap { $0 as? NSScrollView }.first,
            "the container is expected to hold a scroll view"
        )
    }

    private static func lineViews(in scrollView: NSScrollView) -> [AppleMusicLyrics.SyncedLyricsLineView] {
        scrollView.documentView?.subviews.compactMap { $0 as? AppleMusicLyrics.SyncedLyricsLineView } ?? []
    }

    private static func advanceHighlight(
        _ container: AppleMusicLyrics.SyncedLyricsContainerView,
        lyrics: Lyrics,
        through originalIndices: [Int]
    ) {
        for originalIndex in originalIndices {
            container.update(
                lyrics: lyrics,
                highlightedLineIndex: originalIndex,
                mainFontSize: 30,
                translationFontSize: 16
            )
            container.layoutSubtreeIfNeeded()
        }
    }

    private static func clipBoundsSprings(in scrollView: NSScrollView) -> [CASpringAnimation] {
        guard let clipLayer = scrollView.contentView.layer else { return [] }
        return clipLayer.animationKeys()?.compactMap { animationKey in
            clipLayer.animation(forKey: animationKey) as? CASpringAnimation
        }.filter { animation in
            animation.keyPath == "bounds.origin.y"
        } ?? []
    }

    private static func linePositionSprings(in scrollView: NSScrollView) -> [CASpringAnimation] {
        lineViews(in: scrollView).reduce(into: [CASpringAnimation]()) { animations, lineView in
            guard let lineLayer = lineView.layer else { return }
            let lineAnimations = lineLayer.animationKeys()?.compactMap { animationKey in
                lineLayer.animation(forKey: animationKey) as? CASpringAnimation
            }.filter { animation in
                animation.keyPath == "position.y"
            } ?? []
            animations.append(contentsOf: lineAnimations)
        }
    }

    @Test func normalLineChangeUsesOneClipSpringAndAnchorsTheSelectedBaseline() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer()
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3, 4])

        let scrollView = try Self.scrollView(of: container)
        let clipBoundsSprings = Self.clipBoundsSprings(in: scrollView)
        #expect(clipBoundsSprings.count == 1)
        let spring = try #require(
            clipBoundsSprings.first,
            "a normal line change should animate the clip bounds"
        )
        #expect(Self.linePositionSprings(in: scrollView).isEmpty)
        #expect(abs(Double(spring.mass) - 1) < 0.001)
        #expect(abs(Double(spring.stiffness) - 100) < 1)
        #expect(abs(Double(spring.damping) - 18) < 0.5)

        let targetClipOrigin = try CGFloat(#require(spring.toValue as? CGFloat))
        #expect(abs(scrollView.contentView.bounds.origin.y - targetClipOrigin) < 0.5)

        let selectedLine = try #require(Self.lineViews(in: scrollView).first { $0.originalIndex == 4 })
        let selectedBaselineInViewport = selectedLine.frame.minY
            - scrollView.contentView.bounds.origin.y
            + selectedLine.mainTextFirstBaselineOffset
        let expectedBaselineInViewport = scrollView.contentView.bounds.height
            * Self.selectedLineBaselineViewportFraction
        #expect(abs(selectedBaselineInViewport - expectedBaselineInViewport) < 1)
    }

    @Test func repeatingTheSameTargetDoesNotRestartTheClipSpring() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer()
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3, 4])
        let scrollView = try Self.scrollView(of: container)
        let firstSpring = try #require(Self.clipBoundsSprings(in: scrollView).first)

        Self.advanceHighlight(container, lyrics: lyrics, through: [4, 4, 4])

        let currentSpring = try #require(Self.clipBoundsSprings(in: scrollView).first)
        #expect(currentSpring.beginTime == firstSpring.beginTime)
        #expect(currentSpring.fromValue as? CGFloat == firstSpring.fromValue as? CGFloat)
        #expect(currentSpring.toValue as? CGFloat == firstSpring.toValue as? CGFloat)
    }

    @Test func interruptedLineChangeContinuesFromTheVisibleClipOrigin() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer()
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])
        let scrollView = try Self.scrollView(of: container)
        let clipLayer = try #require(scrollView.contentView.layer)
        let visibleOriginBeforeInterruption = (clipLayer.presentation() ?? clipLayer).bounds.origin.y

        Self.advanceHighlight(container, lyrics: lyrics, through: [4])

        let replacementSpring = try #require(Self.clipBoundsSprings(in: scrollView).first)
        let replacementStartingOrigin = try CGFloat(#require(replacementSpring.fromValue as? CGFloat))
        #expect(abs(replacementStartingOrigin - visibleOriginBeforeInterruption) < 0.5)
    }

    @Test func tappedLineUsesTheInteractiveClipSpringEvenForALargeJump() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer()
        defer {
            window.contentView = nil
            window.close()
        }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3])
        let scrollView = try Self.scrollView(of: container)
        let targetLine = try #require(Self.lineViews(in: scrollView).first { $0.originalIndex == 8 })
        targetLine.onTap?(lyrics.lines[8])
        Self.advanceHighlight(container, lyrics: lyrics, through: [8])

        let interactiveSpring = try #require(Self.clipBoundsSprings(in: scrollView).first)
        #expect(abs(Double(interactiveSpring.mass) - 2) < 0.001)
        #expect(abs(Double(interactiveSpring.stiffness) - 260) < 1)
        #expect(abs(Double(interactiveSpring.damping) - 50) < 0.5)
    }
}
