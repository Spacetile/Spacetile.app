import AppKit
import SpacetileCore

/// Mouse handling through a session event tap (Accessibility is enough for mouse events):
/// - fn + drag moves a window; fn + right-drag or fn + ⇧ + drag resizes it from the nearest corner
///   (your old yabai `mouse_modifier fn`, plus a one-finger trackpad form). These events are
///   swallowed so the app underneath never sees them.
/// - fn + drag to the left or right screen edge sends the window to the previous or next Space.
/// - A plain title-bar drag of a tiled window shows where it will land and re-tiles on drop.
/// - A plain edge drag of a tiled window moves the split under that edge, live.
/// - Focus follows mouse as soon as the pointer crosses into another window.
///
/// The tap sits in front of every click, so a plain press does no work until it becomes a drag.
final class Mouse {
    private enum Drag {
        /// Plain button down; nothing looked up yet.
        case pressed(start: CGPoint)
        /// Plain drag near tracked windows, with their frames when the drag began. Whichever frame
        /// changes shows what the drag is: a title-bar move or an edge resize. Comparing against
        /// the drag start, not the tile, means a text selection in an oversized window isn't a resize.
        case watching([(window: AXWindow, frame: CGRect)])
        /// Plain edge drag resizing a tiled window.
        case edgeResizing(AXWindow)
        /// The window is being moved, by its title bar or with fn.
        case moving(AXWindow, frame: CGRect, start: CGPoint, byModifier: Bool)
        /// fn + right-drag or fn + ⇧ + drag: `east`/`south` say which corner follows the cursor.
        case resizing(AXWindow, frame: CGRect, start: CGPoint, east: Bool, south: Bool)
    }

    private let manager: WindowManager
    private let overlay = Overlay()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Pointer moves come through a passive monitor, not the tap: the tap holds every event until
    /// its handler returns, so focusing a slow app on hover would stall the cursor.
    private var moveMonitor: Any?
    /// The display under the pointer, so crossing to another one refreshes the menu-bar item.
    private var pointerDisplay: CGDirectDisplayID = 0
    private var drag: Drag?
    private var hovered: WindowID?
    /// Called when macOS switches the tap off, e.g. because Accessibility was revoked.
    var onDisabled: () -> Void = {}
    /// Throttles hit-testing on mouse moves.
    private var lastHitTest = Date.distantPast
    /// Pending neighbour update for a live resize, replaced on every drag event.
    private var liveResizeWork: DispatchWorkItem?

    init(manager: WindowManager) {
        self.manager = manager
        let events: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                     .rightMouseDown, .rightMouseUp, .rightMouseDragged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            let mouse = Unmanaged<Mouse>.fromOpaque(refcon!).takeUnretainedValue()
            // The tap's run loop source is on the main run loop
            nonisolated(unsafe) let event = event
            let swallow = MainActor.assumeIsolated { mouse.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            log.error("mouse event tap unavailable")
            return
        }
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            // CGEvent locations are top-left based, like the AX frames they're compared with
            guard let point = event.cgEvent?.location else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.noteDisplay(at: point)
                guard !self.manager.isPaused else { return }
                self.focusFollowsMouse(at: point)
            }
        }
    }

    /// Removes the tap and the move monitor for good, so nothing stands between the user's input and
    /// the apps. For Accessibility being revoked.
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        moveMonitor.map(NSEvent.removeMonitor)
        moveMonitor = nil
        drag = nil
    }

    /// Refreshes the menu-bar item when the pointer moves onto another display. One window-server
    /// lookup per move; nothing else happens unless the display changed.
    private func noteDisplay(at point: CGPoint) {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1, display != pointerDisplay else { return }
        pointerDisplay = display
        manager.refreshStatus()
    }

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let point = event.location
        let fn = event.flags.contains(.maskSecondaryFn)
        // Paused: every click and drag goes straight to the apps
        if manager.isPaused, type != .tapDisabledByTimeout, type != .tapDisabledByUserInput { return false }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; turn it straight back on. It also turns it off when
            // Accessibility is revoked: never re-enable it then, since an active tap without the
            // permission can hold up every keyboard and mouse event on the Mac
            if AXIsProcessTrusted() { tap.map { CGEvent.tapEnable(tap: $0, enable: true) } }
            onDisabled()
            return false

        case .leftMouseDown:
            // A click on another display's desktop can make it active without a focus event; check
            // after the click goes through, so the tap doesn't hold it up
            DispatchQueue.main.async { [manager] in manager.refreshStatus() }
            guard fn else {
                drag = .pressed(start: point)
                return false
            }
            guard let window = manager.window(at: point), let frame = window.frame else { return false }
            drag = event.flags.contains(.maskShift)
                ? .resizing(window, frame: frame, start: point, east: point.x > frame.midX, south: point.y > frame.midY)
                : .moving(window, frame: frame, start: point, byModifier: true)
            return true

        case .leftMouseDragged:
            switch drag {
            case .pressed(let start):
                // Edge grabs land in the gap between tiles, just outside either neighbour
                let candidates = manager.windows(near: start, slack: 8).compactMap { window in window.frame.map { (window, $0) } }
                drag = candidates.isEmpty ? nil : .watching(candidates)
                return false
            case .watching(let candidates):
                watch(candidates, at: point)
                return false
            case .edgeResizing(let window):
                liveResize(window)
                return false
            case let .moving(window, frame, start, byModifier):
                if byModifier { window.setOrigin(CGPoint(x: frame.minX + point.x - start.x, y: frame.minY + point.y - start.y)) }
                if byModifier, let edge = Self.edge(at: point), let next = manager.adjacentDesktop(of: window.id, forward: edge.right) {
                    overlay.show(edge.strip, as: .send(toSpace: next.position))
                } else {
                    showDrop(window, at: point)
                }
                return byModifier
            case .resizing:
                resizeFromCorner(to: point)
                return true
            default:
                return false
            }

        case .leftMouseUp:
            defer { drag = nil; overlay.hide() }
            switch drag {
            case let .moving(window, _, _, byModifier):
                if byModifier, let edge = Self.edge(at: point) {
                    manager.sendToAdjacentSpace(window.id, forward: edge.right)
                } else if manager.isTiled(window.id) {
                    manager.drop(window.id, at: point)
                }
                return byModifier
            case .edgeResizing(let window):
                finishResize(window)
                return false
            case let .resizing(window, _, _, _, _):
                finishResize(window)
                return true
            default:
                return false
            }

        case .rightMouseDown:
            guard fn else { return false }
            log.notice("fn + secondary click at \(Int(point.x)),\(Int(point.y))")
            guard let window = manager.window(at: point), let frame = window.frame else { return false }
            drag = .resizing(window, frame: frame, start: point, east: point.x > frame.midX, south: point.y > frame.midY)
            return true

        case .rightMouseDragged:
            guard case .resizing = drag else { return false }
            resizeFromCorner(to: point)
            return true

        case .rightMouseUp:
            guard case let .resizing(window, _, _, _, _) = drag else { return false }
            drag = nil
            finishResize(window)
            return true

        default:
            return false
        }
    }

    private func resizeFromCorner(to point: CGPoint) {
        guard case let .resizing(window, frame, start, east, south) = drag else { return }
        let dx = point.x - start.x, dy = point.y - start.y
        window.setFrame(CGRect(x: east ? frame.minX : frame.minX + dx, y: south ? frame.minY : frame.minY + dy,
                               width: frame.width + (east ? dx : -dx), height: frame.height + (south ? dy : -dy)))
        liveResize(window)
    }

    /// Classifies a plain drag by how a candidate's frame changed since the drag began: same size
    /// but moved is a title-bar drag (re-tile on drop); a changed size is an edge drag.
    private func watch(_ candidates: [(window: AXWindow, frame: CGRect)], at point: CGPoint) {
        for (window, start) in candidates where manager.isTiled(window.id) {
            guard let now = window.frame else { continue }
            if now.size.equalTo(start.size, within: 2), !now.origin.equalTo(start.origin, within: 2) {
                drag = .moving(window, frame: now, start: point, byModifier: false)
                return showDrop(window, at: point)
            }
            if !now.size.equalTo(start.size, within: 2) {
                drag = .edgeResizing(window)
                return liveResize(window)
            }
        }
    }

    /// Re-lays out the neighbours of a window being resized once the pointer pauses for 60ms.
    /// Updating on every drag event made the neighbours visibly judder.
    private func liveResize(_ window: AXWindow) {
        liveResizeWork?.cancel()
        let work = DispatchWorkItem { [manager] in manager.userResized(window.id, live: true) }
        liveResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func finishResize(_ window: AXWindow) {
        liveResizeWork?.cancel()
        manager.userResized(window.id)
    }

    /// Whether `point` is against the left or right edge of the main display, with the strip to highlight.
    /// The left or right edge of the display under `point`, if it's an outer edge. An edge shared
    /// with another display is how a window crosses onto it, so it doesn't send to a Space.
    private static func edge(at point: CGPoint) -> (right: Bool, strip: CGRect)? {
        let desktops = Spaces.desktops
        guard let display = desktops.display(containing: point) else { return nil }
        let frame = display.frame
        // Wide enough to hold the "Send to Space N" label
        if point.x <= frame.minX + 2, desktops.isOuterEdge(right: false, of: display) {
            return (false, CGRect(x: frame.minX, y: frame.minY, width: 220, height: frame.height))
        }
        if point.x >= frame.maxX - 2, desktops.isOuterEdge(right: true, of: display) {
            return (true, CGRect(x: frame.maxX - 220, y: frame.minY, width: 220, height: frame.height))
        }
        return nil
    }

    private func showDrop(_ window: AXWindow, at point: CGPoint) {
        if let drop = manager.dropHighlight(dragging: window.id, at: point) { overlay.show(drop.rect, as: drop.kind) } else { overlay.hide() }
    }

    /// Focuses the window under the pointer when it changes, hit-testing at most every 16ms.
    private func focusFollowsMouse(at point: CGPoint) {
        guard manager.focusFollowsMouse, drag == nil, Date().timeIntervalSince(lastHitTest) > 0.016 else { return }
        lastHitTest = Date()
        let window = manager.window(at: point)
        guard window?.id != hovered else { return }
        hovered = window?.id
        window.map(manager.focusUnderMouse)
    }
}

private extension CGSize {
    func equalTo(_ other: CGSize, within tolerance: CGFloat) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

private extension CGPoint {
    func equalTo(_ other: CGPoint, within tolerance: CGFloat) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}

