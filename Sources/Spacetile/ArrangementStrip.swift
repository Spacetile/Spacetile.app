import SpacetileCore
import SwiftUI

/// The displays drawn to scale where they sit, each with its wallpaper and the main one with the
/// menu bar, as System Settings ▸ Displays shows them. Clicking one selects it, when `select` is given.
struct ArrangementStrip: View {
    struct Item: Identifiable {
        /// The display's UUID or signature, which also finds its wallpaper.
        let id: String
        let name: String
        let frame: CGRect
        /// Outlined in the accent colour: the active display in the mini-map.
        var highlighted = false
    }

    let items: [Item]
    var selected: String?
    var select: ((String) -> Void)?
    var height: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            let fitted = Arrangement.fit(items.map(\.frame), in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let rect = fitted[index].insetBy(dx: 2, dy: 2)
                    let outlined = item.highlighted || item.id == selected
                    // A button, so choosing works from the keyboard and VoiceOver; without `select` it does nothing
                    Button { select?(item.id) } label: {
                        WallpaperFill(image: Wallpaper.image(for: item.id), cornerRadius: 3)
                            .overlay(alignment: .top) {
                                // The menu bar sits on the main display, at the origin
                                if item.frame.origin == .zero {
                                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3).fill(.white.opacity(0.85))
                                        .frame(height: max(3, rect.height * 0.07))
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                Text(item.name).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(3)
                            }
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(outlined ? Color.accentColor : .black.opacity(0.25), lineWidth: outlined ? 2 : 0.5))
                            .frame(width: rect.width, height: rect.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: rect.minX, y: rect.minY)
                    .help(item.name)
                    .accessibilityLabel(item.name + (item.highlighted ? ", active" : ""))
                }
            }
        }
        .frame(height: height)
    }
}
