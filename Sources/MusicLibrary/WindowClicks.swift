import AppKit

/// Lets the whole title bar drag the window. The window's title sits in a container that spans the toolbar's row
/// from the title to the items on the right, and it keeps a click there to itself, so the window only moved from a
/// thin strip at its top edge. A click that lands on the title, or on the title bar's empty space, starts a window
/// drag here instead; toolbar items (buttons, the search field) and the window's buttons keep their clicks. A double
/// click does what System Settings ▸ Desktop & Dock says a title bar double click does.
@MainActor
enum TitleBarDrag {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, !window.styleMask.contains(.fullScreen),
                  let frame = window.contentView?.superview,
                  let hit = frame.hitTest(event.locationInWindow), isTitleBarSpace(hit) else { return event }
            if event.clickCount == 2 {
                doubleClicked(window)
            } else {
                window.performDrag(with: event)
            }
            return nil
        }
    }

    /// The view is part of the title bar, outside any toolbar item and any control other than the title's own text.
    /// AppKit's view classes are private, so they're recognized by name; when that stops matching, clicks simply go
    /// where they always did.
    static func isTitleBarSpace(_ hit: NSView) -> Bool {
        var view: NSView? = hit
        while let v = view {
            let name = String(describing: type(of: v))
            if name.contains("ToolbarItemView") || name.contains("SearchToolbarItem") { return false }
            if v is NSControl, !name.contains("TitleField") { return false }
            if name == "NSTitlebarContainerView" { return true }
            view = v.superview
        }
        return false
    }

    private static func doubleClicked(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}

/// Clicking the sidebar row that's already selected goes back to its main page (the album list from an album opened
/// there, say). The sidebar's list doesn't report a click on the row that's selected, and a gesture on its rows takes
/// clicks away from it, so the click is looked at here, before the list gets it, and passed on unchanged. The sidebar
/// is the window's one list in the source list style.
@MainActor
enum SidebarReclick {
    private static var monitor: Any?

    static func install(_ reselected: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 1, let frame = event.window?.contentView?.superview,
                  let hit = frame.hitTest(event.locationInWindow), let list = sidebar(containing: hit) else { return event }
            let row = list.row(at: list.convert(event.locationInWindow, from: nil))
            if row >= 0, row == list.selectedRow {
                // After the list has handled the click.
                DispatchQueue.main.async { reselected() }
            }
            return event
        }
    }

    private static func sidebar(containing view: NSView) -> NSOutlineView? {
        var current: NSView? = view
        while let v = current {
            if let outline = v as? NSOutlineView { return outline.style == .sourceList ? outline : nil }
            current = v.superview
        }
        return nil
    }
}
