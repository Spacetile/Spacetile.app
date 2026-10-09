import AppKit
import ImageIO
import SwiftUI

/// Each display's desktop picture, scaled down, for drawing displays the way System Settings ▸
/// Displays does.
enum Wallpaper {
    private static var thumbnails: [URL: NSImage] = [:]

    /// The picture on the connected display with this UUID or signature, or the main display's
    /// when `display` is nil. Nil when that display isn't connected or its picture can't be read,
    /// as with some dynamic wallpapers.
    static func image(for display: String?) -> NSImage? {
        guard let screen = display.map(Spaces.screen(matching:)) ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached = thumbnails[url] { return cached }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: .zero)
        thumbnails[url] = image
        return image
    }
}

/// A display's wallpaper filling its shape, or a plain fill when there's no picture to show.
struct WallpaperFill: View {
    let image: NSImage?
    var cornerRadius: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if let image {
            // The picture fills whatever space it's given, cropped, without asking for more
            Color.clear
                .overlay { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                .clipShape(shape)
        } else {
            shape.fill(.quaternary)
        }
    }
}
