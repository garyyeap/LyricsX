import Cocoa

/// `NSTabViewController` leaves the window size to Auto Layout, and Auto Layout
/// only moves it when the selected pane pins itself to a single size. A pane
/// whose content can stretch — a table view inside a scroll view, a grid view,
/// a nested tab view — is satisfied by whatever size the previously selected
/// pane left behind, because the window's own "stay put" constraint outranks
/// anything the pane merely allows. The visible symptom is a tab that opens at
/// a different height depending on which tab you came from.
///
/// Sizing the window from the selected pane's fitting size makes each tab's
/// size depend only on that tab.
class PreferenceTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        resizeWindowToFitSelectedTabViewItem()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        resizeWindowToFitSelectedTabViewItem()
    }

    private func resizeWindowToFitSelectedTabViewItem() {
        guard let window = view.window,
              children.indices.contains(selectedTabViewItemIndex)
        else { return }

        // Measure the pane itself rather than this controller's own view: the
        // Display pane nests another NSTabView, and asking the outer view for
        // its fitting size reports the size it currently has instead of the one
        // its content needs, which would just preserve the stale window size.
        let paneView = children[selectedTabViewItemIndex].view
        paneView.layoutSubtreeIfNeeded()

        let fittingContentSize = paneView.fittingSize
        guard fittingContentSize.width > 0, fittingContentSize.height > 0 else { return }

        var targetFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: fittingContentSize)
        )
        guard targetFrame.size != window.frame.size else { return }

        // Grow and shrink downwards so the title bar stays where the user left it.
        targetFrame.origin.x = window.frame.origin.x
        targetFrame.origin.y = window.frame.maxY - targetFrame.height
        window.setFrame(targetFrame, display: true)
    }
}

class PreferenceViewController: NSViewController {}
