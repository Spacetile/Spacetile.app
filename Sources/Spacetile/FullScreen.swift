import AppKit
import SpacetileCore

/// Native full screen and Split View, through Accessibility. Full screen is a window attribute;
/// Split View has no attribute, only the app's own Window menu items, which the app's menu bar
/// exposes to Accessibility like any other control.
enum FullScreen {
    static func isOn(_ window: AXWindow) -> Bool { window.element.value(of: "AXFullScreen") == true }

    /// Turns full screen on or off: the attribute where the app allows setting it, otherwise the
    /// window's green button, which toggles. Returns whether either worked.
    @discardableResult static func set(_ window: AXWindow, on: Bool) -> Bool {
        guard isOn(window) != on else { return true }
        Spaces.expectLeaving()
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window.element, "AXFullScreen" as CFString, &settable)
        if settable.boolValue,
           AXUIElementSetAttributeValue(window.element, "AXFullScreen" as CFString, on as CFBoolean) == .success { return true }
        guard let button: AXUIElement = window.element.value(of: kAXFullScreenButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// The Window menu item that starts Split View with the focused window on the left or right:
    /// its identifier, the same in every language, and its English titles for apps that leave the
    /// identifier off. macOS 15 and later put it under Window ▸ Full-Screen Tile, earlier releases
    /// straight in the Window menu.
    private static func item(left: Bool) -> (identifier: String, titles: Set<String>) {
        left ? ("_tileLeft:", ["Left of Screen", "Tile Window to Left of Screen"])
            : ("_tileRight:", ["Right of Screen", "Tile Window to Right of Screen"])
    }

    /// Presses the app's own "Full-Screen Tile ▸ Left (or Right) of Screen" for its focused window,
    /// which puts it full screen on that side and has macOS ask for the window on the other side.
    /// The app has to be frontmost: macOS only fills that submenu for the active app. Returns false
    /// when the app has no such item, or it's disabled.
    static func tile(pid: pid_t, left: Bool) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        let wanted = item(left: left)
        guard let menuBar: AXUIElement = app.value(of: kAXMenuBarAttribute),
              let item = find(in: menuBar, depth: 0, where: { $0.value(of: kAXIdentifierAttribute) == wanted.identifier })
                ?? find(in: menuBar, depth: 0, where: { ($0.value(of: kAXTitleAttribute) as String?).map(wanted.titles.contains) == true })
        else { return false }
        Spaces.expectLeaving()
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Finishes a Split View started with `tile`: macOS shows the other windows as thumbnails on
    /// the far half to choose from, and only a click chooses one. Waits up to two seconds for
    /// `partner`'s thumbnail to settle inside `far`, away from where the window was, clicks it and
    /// puts the pointer back. Calls `done` with whether it clicked.
    static func choose(_ partner: WindowID, in far: CGRect, then done: @escaping @MainActor (Bool) -> Void) {
        let start = bounds(of: partner)
        func poll(_ attempts: Int, last: CGRect?) {
            let now = bounds(of: partner)
            // Moved from the window's own frame, inside the far half, and still since the last look
            guard let thumbnail = now, thumbnail != start, thumbnail == last, far.contains(CGPoint(x: thumbnail.midX, y: thumbnail.midY)) else {
                guard attempts > 0 else { return done(false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { poll(attempts - 1, last: now) }
                return
            }
            click(thumbnail, then: done)
        }
        poll(14, last: nil)
    }

    /// A window's frame on screen now, nil when it isn't showing.
    private static func bounds(of window: WindowID) -> CGRect? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.first { $0[kCGWindowNumber as String] as? WindowID == window }
            .flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
    }

    private static func click(_ thumbnail: CGRect, then done: @escaping @MainActor (Bool) -> Void) {
        // The picker ignores a click whose events arrive together, so they go 60 ms apart
        let pointer = CGEvent(source: nil)?.location
        let point = CGPoint(x: thumbnail.midX, y: thumbnail.midY)
        for (step, type) in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(step)) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let pointer { CGWarpMouseCursorPosition(pointer) }
            done(true)
        }
    }

    /// The first enabled menu item `matches` accepts, searching the menu bar's menus and their
    /// submenus. Full-Screen Tile is two levels down; deeper isn't searched, to stay quick.
    private static func find(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth <= 4 else { return nil }
        let children: [AXUIElement] = element.value(of: kAXChildrenAttribute) ?? []
        for child in children {
            if child.value(of: kAXRoleAttribute) == kAXMenuItemRole as String, matches(child), child.value(of: kAXEnabledAttribute) != false {
                return child
            }
            if let found = find(in: child, depth: depth + 1, where: matches) { return found }
        }
        return nil
    }
}
