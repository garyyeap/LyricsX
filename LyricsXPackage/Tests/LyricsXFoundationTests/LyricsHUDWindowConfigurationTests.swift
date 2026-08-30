import AppKit
import Testing
@testable import LyricsXFoundation

@Test @MainActor
func lyricsHUDWindowJoinsEverySpaceAfterConfiguration() {
    let window = NSPanel(
        contentRect: .zero,
        styleMask: [.titled, .utilityWindow],
        backing: .buffered,
        defer: false
    )

    LyricsHUDWindowConfiguration.apply(to: window)

    #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(!window.collectionBehavior.contains(.moveToActiveSpace))
    #expect(window.collectionBehavior == LyricsHUDWindowConfiguration.collectionBehavior)
}

@Test
func lyricsWindowToggleUsesActualWindowVisibility() {
    #expect(
        LyricsWindowPresentationDecision.action(
            isWindowVisible: false,
            isApplicationActive: false
        ) == .show
    )
    #expect(
        LyricsWindowPresentationDecision.action(
            isWindowVisible: true,
            isApplicationActive: false
        ) == .bringToFront
    )
    #expect(
        LyricsWindowPresentationDecision.action(
            isWindowVisible: true,
            isApplicationActive: true
        ) == .close
    )
}
