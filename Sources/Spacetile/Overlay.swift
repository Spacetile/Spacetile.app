import AppKit
import SpacetileCore
import SwiftUI

/// A translucent highlight marking where a window will land, coloured by what will happen and
/// labelled in the middle. Click-through.
final class Overlay {
    /// What the highlight means, which sets its colour and label.
    enum Kind: Equatable {
        case swap(with: String)
        case insert(Direction, beside: String)
        case fillHole
        case send(toSpace: Int)
        case moveToDisplay(String)
        case preselect
        /// A split that didn't happen, and why.
        case refused(String)
        /// What to do next to finish something Spacetile started, like choosing a Split View partner.
        case hint(String)

        var color: Color {
            switch self {
            case .swap: .orange
            case .insert: .accentColor
            case .fillHole: .green
            case .send, .moveToDisplay: .purple
            case .preselect: .teal
            case .refused: .red
            case .hint: .blue
            }
        }

        var label: String {
            switch self {
            case .swap(let app): "Swap with \(app)"
            case let .insert(side, app):
                switch side {
                case .west: "Insert left of \(app)"
                case .east: "Insert right of \(app)"
                case .north: "Insert above \(app)"
                case .south: "Insert below \(app)"
                }
            case .fillHole: "Fill empty tile"
            case .send(let space): "Send to Space \(space)"
            case .moveToDisplay(let name): "Move to \(name)"
            case .preselect: "Next window goes here"
            case .refused(let reason): reason
            case .hint(let text): text
            }
        }

        var symbol: String {
            switch self {
            case .swap: "arrow.left.arrow.right"
            case .insert(let side, _):
                switch side {
                case .west: "arrow.left.to.line"
                case .east: "arrow.right.to.line"
                case .north: "arrow.up.to.line"
                case .south: "arrow.down.to.line"
                }
            case .fillHole: "square.dashed.inset.filled"
            case .send: "rectangle.portrait.and.arrow.right"
            case .moveToDisplay: "display"
            case .preselect: "plus.rectangle.on.rectangle"
            case .refused: "exclamationmark.triangle"
            case .hint: "hand.tap"
            }
        }
    }

    private let host = NSHostingView(rootView: OverlayView(kind: .preselect))
    private var hideWork: DispatchWorkItem?
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        // Over full-screen apps too, for the Split View hint
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        return panel
    }()

    /// `rect` is in AX coordinates (top-left origin); AppKit wants bottom-left.
    func show(_ rect: CGRect, as kind: Kind) {
        if host.rootView.kind != kind { host.rootView = OverlayView(kind: kind) }
        let primaryHeight = NSScreen.screens[0].frame.height
        panel.setFrame(CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// Shows `kind` over `rect` for a moment, then fades it.
    func flash(_ rect: CGRect, as kind: Kind, for seconds: TimeInterval = 2) {
        hideWork?.cancel()
        panel.alphaValue = 1
        show(rect, as: kind)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.panel.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated { self.hide(); self.panel.alphaValue = 1 }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

extension Overlay {
    /// Development aid for `spacetile-ctl overlay-preview <path>`: every kind side by side.
    static func preview(to path: String) {
        let kinds: [Kind] = [.swap(with: "Safari"), .insert(.west, beside: "Claude"), .fillHole, .send(toSpace: 4), .preselect]
        let renderer = ImageRenderer(content: HStack(spacing: 12) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { OverlayView(kind: $0.element).frame(width: 260, height: 160) }
        }.padding(12).background(Color(white: 0.15)))
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation else { return }
        try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private struct OverlayView: View {
    let kind: Overlay.Kind
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Roughly the corner of a Tahoe window, so the highlight reads as the window it stands in for.
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        ZStack {
            shape.fill(kind.color.opacity(reduceTransparency ? 0.4 : 0.22))
            shape.strokeBorder(kind.color, lineWidth: 2)
            label.padding(8)
        }
    }

    /// The label floats over the windows like a control, so it's glass tinted with the action's
    /// colour, or a solid capsule when Reduce Transparency is on.
    @ViewBuilder private var label: some View {
        let text = Label(kind.label, systemImage: kind.symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .minimumScaleFactor(0.7)
        if reduceTransparency {
            text.background(Capsule().fill(kind.color))
        } else {
            text.glassEffect(.regular.tint(kind.color.opacity(0.8)), in: .capsule)
        }
    }
}
