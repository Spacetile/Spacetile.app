// Exports the Keys catalogue for the Raycast extension: <dir>/catalog.json, plus
// <dir>/assets/regions/<name>.png for each placement, drawn with the tiler's own geometry.
// Usage: swift run spacetile-catalog <Raycast extension dir>
import CoreGraphics
import Foundation
import ImageIO
import SpacetileCore
import UniformTypeIdentifiers

struct Entry: Encodable {
    /// The Raycast command name, e.g. `place-left-3-4`.
    let name: String
    let command: String
    let title: String
    /// Relative to the extension's assets/; nil uses the extension icon.
    let icon: String?
}

struct Section: Encodable {
    let title: String
    let actions: [Entry]
}

/// Lowercase words joined by hyphens; a negative number becomes `minus100` so `border … -100`
/// and `border … 100` stay distinct.
func commandName(_ command: String) -> String {
    command.lowercased()
        .split(separator: " ")
        .map { $0.first == "-" ? "minus" + $0.dropFirst() : String($0) }
        .joined(separator: " ")
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: "-")
}

/// A screen outline with the region the window takes filled in, like the Keys tab's pictures.
func drawRegion(_ region: Region, to url: URL) throws {
    let size = 512
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    // Region.rect works in screen coordinates, origin top-left.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)

    let screen = CGRect(x: 40, y: 88, width: 432, height: 336)
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 40, cornerHeight: 40, transform: nil))
    context.setStrokeColor(CGColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1))
    context.setLineWidth(24)
    context.strokePath()

    let rect = region.rect(in: screen.insetBy(dx: 36, dy: 36), gap: 12)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil))
    context.setFillColor(CGColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1))
    context.fillPath()

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: spacetile-catalog <Raycast extension dir>\n".utf8))
    exit(64)
}
let root = URL(filePath: CommandLine.arguments[1])
let regions = root.appending(path: "assets/regions")
try? FileManager.default.removeItem(at: regions)
try FileManager.default.createDirectory(at: regions, withIntermediateDirectories: true)

func entry(_ action: KeyAction) throws -> Entry {
    let name = commandName(action.command)
    var icon: String?
    if case .region(let region) = action.picture {
        icon = "regions/\(name).png"
        try drawRegion(region, to: regions.appending(path: "\(name).png"))
    }
    return Entry(name: name, command: action.command, title: action.title, icon: icon)
}

// Settings → Keys lists the numbered Spaces first, then the families.
let numbered = (1...10).flatMap { ["space \($0)", "send \($0)"] }
    .map { Entry(name: commandName($0), command: $0, title: KeyAction.title(for: $0), icon: nil) }
let sections = [Section(title: "Spaces", actions: numbered)]
    + (try KeyAction.sections.map { Section(title: $0.title, actions: try $0.actions.map(entry)) })

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try (encoder.encode(sections) + Data("\n".utf8)).write(to: root.appending(path: "catalog.json"))
