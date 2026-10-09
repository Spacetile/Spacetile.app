import AppKit
import SpacetileCore
import CSkyLight

/// One window of another app, reached through the Accessibility API.
/// The handle stays valid after the window leaves the current Space (Phase 0 result),
/// which is what lets hidden Spaces be laid out.
struct AXWindow {
    let id: WindowID
    let pid: pid_t
    let element: AXUIElement

    init?(_ element: AXUIElement, pid: pid_t) {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        self.id = id
        self.pid = pid
        self.element = element
    }

    var appName: String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "" }
    var bundleID: String { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? appName }
    var title: String { element.value(of: kAXTitleAttribute) ?? "" }

    /// Standard, resizable, visible windows are the only ones worth tiling;
    /// dialogs, sheets, palettes and minimised windows are left alone.
    var isTileable: Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        return element.value(of: kAXRoleAttribute) == kAXWindowRole as String
            && element.value(of: kAXSubroleAttribute) == kAXStandardWindowSubrole as String
            && element.value(of: kAXMinimizedAttribute) != true
            && element.value(of: "AXFullScreen") != true
            && settable.boolValue
    }

    var frame: CGRect? {
        guard let position: AXValue = element.value(of: kAXPositionAttribute),
              let size: AXValue = element.value(of: kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    func setOrigin(_ point: CGPoint) {
        var origin = point
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    }

    /// One step of an animation: a single position and size write, without reading the frame first.
    func step(to target: CGRect) {
        var origin = target.origin, size = target.size
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    }

    /// Size, then position, then size again: shrinking first stops the window being pushed back
    /// on-screen at its old size, and the second size write lands a size the move had clamped.
    func setFrame(_ target: CGRect) {
        guard frame?.integral != target.integral else { return }
        var origin = target.origin, size = target.size
        let position = AXValueCreate(.cgPoint, &origin)!, extent = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
    }
}

extension AXUIElement {
    func value<T>(of attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// The windows of an app on the current Space.
    static func windows(of pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        let elements: [AXUIElement] = app.value(of: kAXWindowsAttribute) ?? []
        return elements.compactMap { AXWindow($0, pid: pid) }
    }
}
