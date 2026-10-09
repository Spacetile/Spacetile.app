import AppKit
import SpacetileCore
import SwiftUI

/// Draws the menu-bar item from the status and the Menu Bar settings, as a template image so
/// macOS tints it for light and dark menu bars. Shades come from opacity, which templates keep.
enum MenuBarRenderer {
    static func image(for status: WindowManager.Status, settings: MenuBarSettings, warning: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarContent(status: status, settings: settings, warning: warning))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}

private struct MenuBarContent: View {
    let status: WindowManager.Status
    let settings: MenuBarSettings
    let warning: Bool

    var body: some View {
        HStack(spacing: 5) {
            if warning { Image(systemName: "exclamationmark.triangle.fill") }
            if status.paused { Image(systemName: "pause.circle.fill") }
            ForEach(settings.orderedItems.filter(\.shown), id: \.item) { entry in
                item(entry.item)
            }
            // Template images keep opacity, so a paused item reads as switched off
            .opacity(status.paused ? 0.45 : 1)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.black)
        .fixedSize()
        .frame(height: 22)
    }

    @ViewBuilder private func item(_ item: MenuBarSettings.Item) -> some View {
        switch item {
        case .logo:
            Image(systemName: "square.grid.2x2.fill")
        case .index:
            switch settings.indexStyle {
            case .single: SingleIndex(number: status.space)
            case .stepper: Stepper(current: status.space, slots: status.order)
            case .displays:
                HStack(spacing: 3) {
                    ForEach(Array(status.displays.enumerated()), id: \.offset) { _, display in
                        SingleIndex(number: display.number)
                            .opacity(display.isActive || status.displays.count == 1 ? 1 : 0.4)
                    }
                }
            }
        case .name:
            if let label = status.label { Text(label) }
        case .layout:
            // A full-screen app's Space has no Spacetile layout: macOS lays it out
            Image(systemName: status.isFullScreen ? "arrow.up.backward.and.arrow.down.forward" : status.mode.symbol)
        case .windowCount:
            HStack(spacing: 2) {
                Image(systemName: "macwindow")
                Text("\(status.windowCount)").monospacedDigit()
            }
        case .stacked:
            if status.stacked > 0 { Text("+\(status.stacked)").monospacedDigit() }
        case .profileIcon:
            if let icon = status.profileIcon { Image(systemName: icon) }
        case .profileName:
            if let profile = status.profile { Text(profile) }
        }
    }

}

/// The current Space's position inside a rounded square.
private struct SingleIndex: View {
    let number: Int?

    var body: some View {
        Text(number.map(String.init) ?? "·")
            .font(.system(size: 11, weight: .bold)).monospacedDigit()
            .frame(minWidth: 16, minHeight: 16)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(lineWidth: 1.5))
    }
}

/// One mark per Space in Mission Control order: the current one filled, occupied Desktops
/// outlined, empty ones faint, and full-screen apps' Spaces as small diamonds.
private struct Stepper: View {
    /// The current Space's position.
    let current: Int?
    let slots: [WindowManager.StepSlot]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                let isCurrent = current == index + 1
                switch slot {
                case .desktop(let occupied):
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isCurrent ? AnyShapeStyle(.black) : AnyShapeStyle(.clear))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1.2))
                        .opacity(isCurrent || occupied ? 1 : 0.35)
                        .frame(width: 8, height: 8)
                case .fullScreen:
                    Rectangle()
                        .fill(isCurrent ? AnyShapeStyle(.black) : AnyShapeStyle(.clear))
                        .overlay(Rectangle().strokeBorder(lineWidth: 1.1))
                        .frame(width: 5, height: 5)
                        .rotationEffect(.degrees(45))
                        .frame(width: 7, height: 8)
                }
            }
        }
    }
}
