import AppKit
import LyricsXFoundation
import QuartzCore
import Testing
@testable import AppleMusicLyricsPanel

/// The line-change scroll is the one animation the panel does not drive itself:
/// it hands the clip to Core Animation and lets the render server interpolate.
///
/// That split is the whole point, and it is invisible from the outside — a clip
/// stepped by hand from the display link and a clip on a real spring reach the
/// same place, they just do not arrive in the same number of pieces. Measured on
/// Music at 60 Hz, one 90 pt advance arrives as 28 separate positions over
/// 450 ms; a hand-stepped clip arrives in however many frames the main thread
/// had to spare. So these probes assert the *mechanism*, which is deterministic,
/// rather than a frame count, which is not.
@Suite(.serialized)
@MainActor
struct ScrollSpringProbes {
    /// A dozen plain timed lines, four seconds apart — enough rows for the clip
    /// to have somewhere to travel, and no inline timing to drag the karaoke
    /// engine into a test that is not about it.
    private static func makeLyrics() -> Lyrics? {
        let body = (0 ..< 12)
            .map { index in String(format: "[00:%05.2f]probe line number %d", Double(index) * 4, index) }
            .joined(separator: "\n")
        return Lyrics(body)
    }

    private static func makeMountedContainer() -> (AppleMusicLyrics.SyncedLyricsContainerView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        let container = AppleMusicLyrics.SyncedLyricsContainerView(frame: frame)
        // Never ordered in: the container only needs a window for its display
        // link to arm and for the scroll to take its animated path.
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        return (container, window)
    }

    private static func clipLayer(of container: AppleMusicLyrics.SyncedLyricsContainerView) throws -> CALayer {
        let scrollView = try #require(
            container.subviews.compactMap { $0 as? NSScrollView }.first,
            "the container is expected to hold a scroll view"
        )
        return try #require(scrollView.contentView.layer, "the clip view should be layer-backed")
    }

    /// Advance the highlight far enough to get past the first change, which
    /// deliberately snaps: `advanceFollowing` has no previous position to
    /// measure against yet and treats it as a seek.
    private static func advanceHighlight(
        _ container: AppleMusicLyrics.SyncedLyricsContainerView,
        lyrics: Lyrics,
        through indices: [Int]
    ) {
        for index in indices {
            container.update(
                lyrics: lyrics,
                highlightedLineIndex: index,
                mainFontSize: 30,
                translationFontSize: 16
            )
            container.layoutSubtreeIfNeeded()
        }
    }

    @Test func aLineChangeTravelsOnARealCoreAnimationSpring() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer()
        defer { window.contentView = nil }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3, 4])

        let clipLayer = try Self.clipLayer(of: container)
        let springs = (clipLayer.animationKeys() ?? [])
            .compactMap { clipLayer.animation(forKey: $0) as? CASpringAnimation }
        // No spring here means the clip is being stepped by hand again, which
        // ties its smoothness to how busy the main thread is.
        let clipSpring = try #require(springs.first { $0.keyPath == "bounds.origin.y" })

        // Music's `lineChangeSpringTimingParametersValues`: mass 1, stiffness 100,
        // damping 18. Confirmed on screen at 60 Hz — see the constants' own comment.
        let mass = Double(clipSpring.mass)
        let stiffness = Double(clipSpring.stiffness)
        let damping = Double(clipSpring.damping)
        #expect(abs(mass - 1) < 0.001, "mass \(mass) is not Music's 1")
        #expect(abs(stiffness - 100) < 1, "stiffness \(stiffness) is not Music's 100")
        #expect(abs(damping - 18) < 0.5, "damping \(damping) is not Music's 18")

        let fromValue = try Double(#require(clipSpring.fromValue as? CGFloat))
        let toValue = try Double(#require(clipSpring.toValue as? CGFloat))
        let travel = abs(toValue - fromValue)
        #expect(travel > 1, "the spring spans \(travel) pt — a line change should actually travel")
        // Whatever the animation shows, the model has to be at the destination
        // already: AppKit re-projects the clip's bounds from the view's own ivars
        // on any geometry pass, and everything that reads the scroll position
        // (hit testing, `documentVisibleRect`, the next target) reads the model.
        let modelOriginY = Double(clipLayer.bounds.origin.y)
        #expect(
            abs(modelOriginY - toValue) < 0.5,
            "the clip's model value is \(modelOriginY) but the spring ends at \(toValue)"
        )
    }

    /// Re-centring on a target already being travelled to must not restart the
    /// spring. The interlude hold calls this every display-link frame, and a
    /// spring restarted 60 times a second never gets past its own slow start.
    @Test func recentringOnTheSameTargetLeavesTheSpringAlone() throws {
        let lyrics = try #require(Self.makeLyrics(), "fixture lyrics failed to parse")
        let (container, window) = Self.makeMountedContainer()
        defer { window.contentView = nil }

        Self.advanceHighlight(container, lyrics: lyrics, through: [2, 3, 4])
        let clipLayer = try Self.clipLayer(of: container)
        let firstSpring = try #require(
            (clipLayer.animationKeys() ?? [])
                .compactMap { clipLayer.animation(forKey: $0) as? CASpringAnimation }
                .first { $0.keyPath == "bounds.origin.y" }
        )
        let firstBeginTime = firstSpring.beginTime

        // Same highlighted line, several more times over.
        Self.advanceHighlight(container, lyrics: lyrics, through: [4, 4, 4])

        let currentSpring = (clipLayer.animationKeys() ?? [])
            .compactMap { clipLayer.animation(forKey: $0) as? CASpringAnimation }
            .first { $0.keyPath == "bounds.origin.y" }
        if let currentSpring {
            #expect(
                currentSpring.beginTime == firstBeginTime,
                "the spring was restarted by a re-centre onto the target it was already heading for"
            )
        }
    }
}
