import AppKit
import SpacetileCore
import SwiftUI

/// The mini-map's Desktops in a glass panel across the top of the screen, like Mission Control's
/// Spaces bar: a row per display that scrolls sideways, and it stays open while you switch Desktops
/// and move windows around. A click outside it or Esc closes it, as the mini-map does. It keeps
/// itself current while it's open: on every Desktop change and app switch, and every couple of
/// seconds for windows that move on their own. Window pictures, which cost more, refresh less often.
final class SpacesWindow {
    private let model: MiniMapModel
    private let panel = MenuBarPanel()
    private let hosting: NSHostingView<SpacesWindowView>
    private let outsideClicks = OutsideClicks()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var ticks = 0

    init(model: MiniMapModel) {
        self.model = model
        hosting = NSHostingView(rootView: SpacesWindowView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = MenuBarPanel.glass(around: hosting)
        panel.onCancel = { [weak self] in self?.close() }
    }

    func show() {
        model.refresh()
        // The screen's full width under the menu bar, inset like the mini-map, tall enough for
        // cards about 160 pt high
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let height = min(visible.height - 12, SpacesWindowView.height(card: 160, displays: model.displays.count))
        let frame = NSRect(x: visible.minX + 8, y: visible.maxY - height - 6, width: visible.width - 16, height: height)
        panel.setFrame(frame, display: true)
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        if !panel.isVisible { panel.reveal() }
        outsideClicks.start(inside: [panel]) { [weak self] in self?.close() }
        startRefreshing()
    }

    func close() {
        guard panel.isVisible else { return }
        outsideClicks.stop()
        stopRefreshing()
        panel.orderOut(nil)
    }

    private func startRefreshing() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Pictures every tenth second tick; positions every tick
                self.ticks += 1
                self.model.refresh(previews: self.ticks % 5 == 0)
            }
        }
        timer?.tolerance = 0.5
    }

    private func stopRefreshing() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }
}

/// A row per display that scrolls sideways; cards fill the window's height, shared between the
/// rows, and run off to the right as Mission Control's Spaces bar does.
struct SpacesWindowView: View {
    var model: MiniMapModel

    private static let padding: CGFloat = 20
    /// Between display rows, as `SpacesMap` spaces them.
    private static let rowGap: CGFloat = 14

    /// Around each card: the Desktop's label and the scroll bar, plus the display's name when
    /// there are several.
    private static func chrome(displays: Int) -> CGFloat { 3 + 15 + 14 + (displays > 1 ? 18 + 6 : 0) }

    static func height(card: CGFloat, displays: Int) -> CGFloat {
        let rows = CGFloat(max(displays, 1))
        return rows * (card + chrome(displays: displays)) + (rows - 1) * rowGap + 2 * padding
    }

    var body: some View {
        GeometryReader { geometry in
            let count = model.displays.count, rows = CGFloat(max(count, 1))
            let shared = geometry.size.height - 2 * Self.padding - (rows - 1) * Self.rowGap
            let card = max(60, shared / rows - Self.chrome(displays: count))
            SpacesMap(model: model, cardHeight: card, close: {}, wraps: false)
                .padding(Self.padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .opacity(model.status.paused ? 0.5 : 1)
    }
}
