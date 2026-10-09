import AppKit
import SpacetileCore
import SwiftUI

/// Marks the focused window: an outline, in the accent colour unless one is chosen, ordered just above it, and a shade
/// over its display ordered just below it, so every window behind it looks dimmed. Both are
/// Spacetile's own click-through windows. Placing a window of your own next to another app's in
/// the stacking order works with SIP on; changing another app's window's opacity, as yabai does,
/// is what needs SIP off.
final class FocusHighlight {
    var showsBorder = false { didSet { if showsBorder != oldValue { update() } } }
    var dims = false { didSet { if dims != oldValue { update() } } }
    /// nil draws the outline in the accent colour.
    var borderColor: NSColor? { didSet { if borderColor != oldValue { restyleBorder() } } }
    var borderOpacity: Double = 1 { didSet { if borderOpacity != oldValue { restyleBorder() } } }
    var dimOpacity: Double = 0.3 {
        didSet { if dimOpacity != oldValue { shade.backgroundColor = NSColor.black.withAlphaComponent(dimOpacity) } }
    }
    /// Nothing is drawn while tiling is paused.
    var isSuspended = false { didSet { if isSuspended != oldValue { update() } } }

    static let borderWidth: CGFloat = 4
    /// Roughly a Tahoe window's corner, as `Overlay` uses, so the outline hugs the window.
    static let cornerRadius: CGFloat = 16

    private var target: AXWindow?
    /// Watches the target for moves, resizes and closing, so the border keeps up with drags.
    private var observer: AXObserver?
    private var watched: WindowID?
    private var recheck: DispatchWorkItem?
    /// Whether either panel may be on screen, so the panels aren't made just to be hidden.
    private var isShowing = false

    private lazy var borderView = NSHostingView(rootView: BorderView(color: borderColor, opacity: borderOpacity))
    private lazy var border = FocusHighlight.panel(content: borderView)
    private lazy var shade: NSPanel = {
        let panel = FocusHighlight.panel(content: nil)
        panel.backgroundColor = NSColor.black.withAlphaComponent(dimOpacity)
        return panel
    }()

    private func restyleBorder() {
        borderView.rootView = BorderView(color: borderColor, opacity: borderOpacity)
    }

    private var isActive: Bool { (showsBorder || dims) && !isSuspended }

    /// Follows `window`, the focused window, or hides with no window focused.
    func follow(_ window: AXWindow?) {
        target = window
        update()
        // The window server raises a newly focused window a moment after focus moves. Order again
        // once it has, or windows still in front of its old position would stay undimmed
        recheck?.cancel()
        guard isActive else { return }
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.refresh() } }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func update() {
        let wanted = isActive ? target : nil
        if wanted?.id != watched { watch(wanted) }
        refresh()
    }

    private func refresh() {
        guard isActive, let target, target.pid != getpid(), let frame = target.frame, frame.width > 0, frame.height > 0,
              target.element.value(of: kAXMinimizedAttribute) != true, !FullScreen.isOn(target),
              Self.isOnScreen(target.id) else { return hide() }
        let primaryHeight = NSScreen.screens[0].frame.height
        let rect = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        let number = Int(target.id)
        isShowing = true
        if showsBorder {
            // Outside the window, so none of its content is covered
            border.setFrame(rect.insetBy(dx: -Self.borderWidth, dy: -Self.borderWidth), display: true)
            border.order(.above, relativeTo: number)
        } else {
            border.orderOut(nil)
        }
        if dims, let screen = Self.screen(showing: rect) {
            shade.setFrame(screen.frame, display: true)
            shade.order(.below, relativeTo: number)
        } else {
            shade.orderOut(nil)
        }
    }

    private func hide() {
        guard isShowing else { return }
        isShowing = false
        border.orderOut(nil)
        shade.orderOut(nil)
    }

    private func watch(_ window: AXWindow?) {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        watched = nil
        guard let window else { return }
        var created: AXObserver?
        guard AXObserverCreate(window.pid, focusHighlightCallback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(created, window.element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        watched = window.id
    }

    fileprivate func targetChanged(_ notification: String) {
        if notification == kAXUIElementDestroyedNotification { target = nil }
        update()
    }

    private static func panel(content: NSView?) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // The normal level, so it can sit between other apps' windows
        panel.level = .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Out of Mission Control and ⌘`, and on whichever Space the focused window is
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        if let content { panel.contentView = content }
        return panel
    }

    /// The screen showing most of `rect`, in AppKit coordinates.
    private static func screen(showing rect: CGRect) -> NSScreen? {
        func area(_ screen: NSScreen) -> CGFloat {
            let overlap = screen.frame.intersection(rect)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        return NSScreen.screens.filter { area($0) > 0 }.max { area($0) < area($1) }
    }

    /// Whether the window is showing now; one on another Space has nothing to mark.
    private static func isOnScreen(_ id: WindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]]
        return info?.first?[kCGWindowIsOnscreen as String] as? Bool == true
    }
}

private struct BorderView: View {
    let color: NSColor?
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: FocusHighlight.cornerRadius + FocusHighlight.borderWidth, style: .continuous)
            .strokeBorder(color.map { Color(nsColor: $0) } ?? .accentColor, lineWidth: FocusHighlight.borderWidth)
            .opacity(opacity)
    }
}

extension NSColor {
    /// Reads `"#RRGGBB"`, as `Settings.borderColor` stores it.
    convenience init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// `"#RRGGBB"` in sRGB, dropping alpha.
    var hex: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

// A C function pointer, so it can't carry the target's default main-actor isolation
nonisolated private func focusHighlightCallback(_: AXObserver, element _: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let highlight = Unmanaged<FocusHighlight>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // Added to the main run loop, so this always runs on the main thread
    MainActor.assumeIsolated { highlight.targetChanged(name) }
}
