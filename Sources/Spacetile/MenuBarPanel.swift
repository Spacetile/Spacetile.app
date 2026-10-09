import AppKit

/// A borderless glass panel that drops from the menu bar, as Control Center does: no title bar or
/// buttons, rounded, and able to take keys (for Esc) without making Spacetile the active app. The
/// mini-map and the Spaces window both use one.
final class MenuBarPanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }

    // Borderless panels can't close or minimise, so ⌘W and ⌘M would do nothing; both dismiss it
    override func performClose(_ sender: Any?) { onCancel() }
    override func performMiniaturize(_ sender: Any?) { onCancel() }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        [#selector(performClose), #selector(performMiniaturize)].contains(item.action) || super.validateMenuItem(item)
    }

    /// Fades the panel in and makes it key.
    func reveal() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    /// The system popover material, rounded, behind `content`.
    static func glass(around content: NSView) -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.addSubview(content)
        return background
    }
}

/// Closes something on a click outside it: in another app, or in one of Spacetile's windows other
/// than `inside` ones.
final class OutsideClicks {
    private var monitors: [Any] = []

    func start(inside: [NSWindow], close: @escaping () -> Void) {
        stop()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in
            MainActor.assumeIsolated { close() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { event in
            MainActor.assumeIsolated {
                if !inside.contains(where: { $0 === event.window }) { close() }
            }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
