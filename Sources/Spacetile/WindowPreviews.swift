import AppKit
import ScreenCaptureKit
import SpacetileCore

/// Small pictures of windows' content for the mini-map and the profile editor, through
/// ScreenCaptureKit. Only with Show window previews on and Screen Recording granted; otherwise
/// nothing is captured and those views show app icons. Pictures live in memory and are never saved.
@Observable final class WindowPreviews {
    static let shared = WindowPreviews()

    private(set) var images: [WindowID: CGImage] = [:]
    /// Follows the setting; turning it off forgets every picture.
    var enabled = false {
        didSet { if !enabled { images = [:] } }
    }

    static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures those of `ids` showing on screen, in the background. Only windows on screen can be
    /// captured, so the rest keep their last picture, or their icon until they have one. Views
    /// update as each picture arrives.
    func refresh(_ ids: [WindowID]) {
        guard enabled, Self.permitted, !ids.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            let wanted = Set(ids)
            for window in content.windows where wanted.contains(window.windowID) {
                guard enabled, let image = await Self.capture(window) else { continue }
                images[window.windowID] = image
            }
        }
    }

    /// Forgets the pictures of windows that have closed.
    func keep(only live: Set<WindowID>) {
        images = images.filter { live.contains($0.key) }
    }

    /// A third of the window's size in pixels, which is more than any card draws.
    private static func capture(_ window: SCWindow) async -> CGImage? {
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(frame.width / 3), 1)
        configuration.height = max(Int(frame.height / 3), 1)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
