import AppKit
import CSkyLight

/// Brings a specific window of another app to the front and makes it key.
///
/// A background app's `NSRunningApplication.activate()` is cooperative since macOS 14 and can be
/// ignored, and it can't choose which window becomes key. The SkyLight path (the one yabai uses
/// without SIP) can, so it's tried first and the public API is the fallback.
enum Focus {
    /// `kCPSUserGenerated`: the activation counts as user initiated.
    private static let userGenerated: UInt32 = 0x200
    /// `kCPSNoWindows`: make the process frontmost without bringing any of its windows forward.
    private static let noWindows: UInt32 = 0x400

    static func focus(_ window: AXWindow) {
        var psn = ProcessSerialNumber()
        if BSProcessForPID(window.pid, &psn) == noErr,
           _SLPSSetFrontProcessWithOptions(&psn, window.id, userGenerated) == .success {
            makeKey(window.id, psn: &psn)
        } else {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    /// Makes `window` key without changing the window stacking order, so a tiled window under the
    /// pointer can take focus while a floating window stays on top of it (yabai's autofocus).
    ///
    /// Across apps the target app is made frontmost with `kCPSNoWindows`. If that app's key window
    /// is a different one of its windows, the key window is then switched with the resign/become
    /// key event records. The stronger make-key records aren't used: Electron apps raise a window
    /// when told it's key, which put tiles back over floats.
    static func focusWithoutRaise(_ window: AXWindow, current: AXWindow?) {
        var psn = ProcessSerialNumber()
        guard BSProcessForPID(window.pid, &psn) == noErr else { return }
        if let current, current.pid == window.pid {
            switchKey(from: current.id, to: window.id, psn: &psn)
            return
        }
        let appKey = AXUIElementCreateApplication(window.pid).value(of: kAXFocusedWindowAttribute)
            .flatMap { AXWindow($0 as AXUIElement, pid: window.pid)?.id }
        _SLPSSetFrontProcessWithOptions(&psn, window.id, noWindows)
        if let appKey, appKey != window.id { switchKey(from: appKey, to: window.id, psn: &psn) }
    }

    /// Moves key status between two windows of one app without reordering them.
    private static func switchKey(from old: UInt32, to new: UInt32, psn: inout ProcessSerialNumber) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d
        bytes[0x8a] = 0x02 // resign key
        withUnsafeBytes(of: old) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        SLPSPostEventRecordTo(&psn, &bytes)
        usleep(10_000)
        bytes[0x8a] = 0x01 // become key
        withUnsafeBytes(of: new) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        SLPSPostEventRecordTo(&psn, &bytes)
    }

    /// The frontmost app's process ID from the window server, falling back to NSWorkspace.
    static var frontmostPID: pid_t? {
        var psn = ProcessSerialNumber()
        var pid: pid_t = 0
        if _SLPSGetFrontProcess(&psn) == .success, BSPIDForProcess(&psn, &pid) == noErr, pid > 0 { return pid }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Posts the synthetic event record pair that tells the process which window is key.
    /// Byte layout from yabai's `window_manager_make_key_window`.
    private static func makeKey(_ windowID: UInt32, psn: inout ProcessSerialNumber) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
        for phase: UInt8 in [0x01, 0x02] {
            bytes[0x08] = phase
            SLPSPostEventRecordTo(&psn, &bytes)
        }
    }
}
