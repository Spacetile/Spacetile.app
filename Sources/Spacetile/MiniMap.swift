import AppKit
import SpacetileCore
import SwiftUI

/// The menu-bar panel: every Space as a card with its windows drawn where they are. Click a card to
/// switch to it, click a window to go to it, drag a window onto another card to send it. It drops
/// from the menu bar without an arrow, as Control Center and Wi-Fi do, and closes on a click
/// elsewhere, Esc, or another app coming forward.
final class MiniMap {
    let model: MiniMapModel
    private let panel = MenuBarPanel()
    private let hosting: NSHostingView<MiniMapView>
    private weak var button: NSStatusBarButton?
    private let outsideClicks = OutsideClicks()
    private var activation: NSObjectProtocol?

    init(manager: WindowManager, captureLayout: @escaping () -> Void, editProfiles: @escaping () -> Void,
         openSettings: @escaping () -> Void, showWelcome: @escaping () -> Void, openSpaces: @escaping () -> Void,
         checkForUpdates: @escaping () -> Void) {
        model = MiniMapModel(manager: manager, captureLayout: captureLayout, editProfiles: editProfiles,
                             openSettings: openSettings, showWelcome: showWelcome, openSpaces: openSpaces,
                             checkForUpdates: checkForUpdates)
        hosting = NSHostingView(rootView: MiniMapView(model: model) {})
        hosting.rootView = MiniMapView(model: model) { [weak self] in self?.close() }
        panel.contentView = MenuBarPanel.glass(around: hosting)
        panel.onCancel = { [weak self] in self?.close() }
    }

    /// Development aid for `spacetile-ctl minimap-shot <path>`. Rendered by SwiftUI on a window-like
    /// background, since caching the panel's view drops its vibrant text.
    func snapshot(from _: NSStatusBarButton, to path: String) {
        model.refresh()
        let renderer = ImageRenderer(content: MiniMapView(model: model) {}
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation else { return }
        try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func toggle(from button: NSStatusBarButton) {
        if panel.isVisible { return close() }
        self.button = button
        model.refresh()
        // Size and place before showing, under the item and inside the screen
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        guard let itemFrame = button.window?.frame, let screen = button.window?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = min(max(itemFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(CGRect(x: x, y: itemFrame.minY - size.height - 6, width: size.width, height: size.height), display: true)
        panel.reveal()
        button.highlight(true)
        watchForDismissal()
    }

    func close() {
        guard panel.isVisible else { return }
        outsideClicks.stop()
        activation.map(NSWorkspace.shared.notificationCenter.removeObserver)
        activation = nil
        panel.orderOut(nil)
        button?.highlight(false)
    }

    /// A click in another app, or in one of Spacetile's windows outside the panel (except the
    /// menu-bar item, which toggles it), or another app coming forward closes the panel.
    private func watchForDismissal() {
        outsideClicks.start(inside: [panel, button?.window].compactMap { $0 }) { [weak self] in self?.close() }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.close() }
        }
    }
}

@Observable final class MiniMapModel {
    var displays: [WindowManager.MiniDisplay] = []
    var status = WindowManager.Status()
    /// Shortcuts the footer shows beside its actions, from config.json.
    var settings = Settings.default
    var configError: String?
    /// Accessibility was turned off while running: tiling is paused until it's back.
    var accessibilityLost = false
    var profiles: [Profile] = []
    var profileProblems: [ProfileStore.Problem] = []
    let manager: WindowManager
    let captureLayout: () -> Void
    let editProfiles: () -> Void
    let openSettings: () -> Void
    let showWelcome: () -> Void
    let openSpaces: () -> Void
    let checkForUpdates: () -> Void

    init(manager: WindowManager, captureLayout: @escaping () -> Void, editProfiles: @escaping () -> Void,
         openSettings: @escaping () -> Void, showWelcome: @escaping () -> Void, openSpaces: @escaping () -> Void,
         checkForUpdates: @escaping () -> Void) {
        self.manager = manager
        self.captureLayout = captureLayout
        self.editProfiles = editProfiles
        self.openSettings = openSettings
        self.showWelcome = showWelcome
        self.openSpaces = openSpaces
        self.checkForUpdates = checkForUpdates
    }

    /// Reads the Spaces again; `previews` also captures window pictures, which costs more.
    func refresh(previews: Bool = true) {
        displays = manager.miniMap()
        if previews { WindowPreviews.shared.refresh(displays.flatMap(\.spaces).flatMap(\.windows).map(\.id)) }
        (profiles, profileProblems) = ProfileStore.load()
    }

    /// The first chord bound to `command`, as a menu would show it, or nil with shortcuts off.
    func shortcut(for command: String) -> String? {
        guard settings.usesShortcuts else { return nil }
        return settings.keys.filter { $0.value == command }.keys.sorted().first.flatMap(KeyChord.init)?.symbols
    }

    func send(_ window: WindowID, to space: Spaces.ID, keepingDisplay: Bool = true) {
        manager.send(window, to: space, keepingDisplay: keepingDisplay)
        // The window server applies the move within ~15ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.refresh() }
    }
}

struct MiniMapView: View {
    var model: MiniMapModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiniMapHeader(model: model, close: close)
            Divider()
            VStack(alignment: .trailing, spacing: 4) {
                // Every Desktop in a window of its own, bigger and staying open while you work
                Button {
                    close()
                    model.openSpaces()
                } label: {
                    Label("Open in a Window", systemImage: "arrow.up.forward.app").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Open the Spaces map in a window")
                SpacesMap(model: model, cardHeight: 51, close: close)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
            .opacity(model.status.paused ? 0.5 : 1)
            Divider()
            MiniMapFooter(model: model, close: close)
        }
        .frame(width: 440)
    }
}

/// Every display's Desktops as rows of cards, as the Spaces bar in Mission Control shows them.
/// Click a card to switch to it, click a window to go to it, drag a window onto another card to
/// send it. The mini-map closes after switching; the Spaces window stays.
struct SpacesMap: View {
    var model: MiniMapModel
    /// Card height; widths follow each display's shape.
    let cardHeight: CGFloat
    /// After switching Desktop or going to a window.
    let close: () -> Void
    /// Wrap a display's Desktops onto more lines (the mini-map), or keep them on one line that
    /// scrolls sideways, as Mission Control's Spaces bar does (the Spaces window).
    var wraps = true
    /// The window under the pointer, outlined so it reads as something to grab.
    @State private var hovered: WindowID?
    /// The card a dragged window would land on.
    @State private var dropTarget: Spaces.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let order = Arrangement.rows(model.displays.map(\.frame)).flatMap { $0 }
            ForEach(order, id: \.self) { index in row(model.displays[index]) }
        }
    }

    private func row(_ display: WindowManager.MiniDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.displays.count > 1 {
                Text(display.name + (display.isActive ? " · active" : ""))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if wraps {
                FlowLayout(spacing: 8, justified: true) {
                    ForEach(display.spaces) { space in spaceCard(space, on: display) }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(display.spaces) { space in spaceCard(space, on: display) }
                    }
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    /// A Desktop's card, or a full-screen app's between them.
    @ViewBuilder private func spaceCard(_ space: WindowManager.MiniSpace, on display: WindowManager.MiniDisplay) -> some View {
        if space.isFullScreen { fullScreenCard(space, on: display) } else { card(space, on: display) }
    }

    /// A full-screen app's Space, where Mission Control puts it among the Desktops: narrower than a
    /// Desktop, its window filling it (two side by side in Split View, at their real widths), with
    /// its position and the app's name below. Click to switch to it. Windows
    /// can't be dropped on it: macOS lays out full-screen Spaces itself.
    private func fullScreenCard(_ space: WindowManager.MiniSpace, on display: WindowManager.MiniDisplay) -> some View {
        let height = cardHeight, width = height * min(display.aspect, 1.6) * 0.8
        let panes = space.windows.sorted { $0.rect.minX < $1.rect.minX }
        let names = space.appNames.isEmpty ? "Full screen" : space.appNames
        return VStack(spacing: 3) {
            HStack(spacing: 1.5) {
                ForEach(panes) { window in
                    fullScreenPane(window)
                        .frame(width: panes.count > 1 ? max(window.rect.width, 0.1) * width : width)
                }
                if panes.isEmpty { Rectangle().fill(.quaternary) }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(space.isCurrent ? Color.white : .secondary.opacity(0.3), lineWidth: space.isCurrent ? 2.5 : 0.5))
            .overlay { if space.isCurrent { RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.25), lineWidth: 0.5) } }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                    .font(.system(size: 7, weight: .bold)).foregroundStyle(.white).padding(3)
                    .background(Circle().fill(.black.opacity(0.35))).padding(2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Spaces.switchTo(space.id)
                close()
            }
            .help("\(names), full screen. Click to switch to it.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(names), full screen")
            .accessibilityAddTraits(.isButton)
            Text("\(space.number) \(names)")
                .font(.caption2.weight(space.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(space.isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, space.isCurrent ? 6 : 0).padding(.vertical, space.isCurrent ? 1 : 0)
                .background { if space.isCurrent { Capsule().fill(Color.accentColor) } }
                .frame(maxWidth: max(width, 40))
        }
    }

    /// One side of a full-screen card: the window's picture when previews are on, otherwise its
    /// app's icon on a plain fill.
    private func fullScreenPane(_ window: WindowManager.MiniWindow) -> some View {
        let icon = NSRunningApplication(processIdentifier: window.pid)?.icon
        let preview = WindowPreviews.shared.images[window.id]
        return Rectangle().fill(.background)
            .overlay {
                if let preview {
                    Image(decorative: preview, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else if let icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(maxWidth: 22, maxHeight: 22)
                }
            }
            .clipped()
    }

    private func card(_ space: WindowManager.MiniSpace, on display: WindowManager.MiniDisplay) -> some View {
        let aspect = display.aspect, panels = display.panels
        // An empty Desktop is dimmed, so the ones in use stand out
        let empty = space.windows.isEmpty && !space.isCurrent
        let height = cardHeight, width = height * aspect
        return VStack(spacing: 3) {
            ZStack(alignment: .topLeading) {
                // The display's wallpaper behind its windows, as Mission Control shows a Desktop
                if panels.isEmpty {
                    WallpaperFill(image: Wallpaper.image(for: display.id), cornerRadius: 5)
                } else {
                    // One Desktop shared by every display: each display drawn where it sits
                    ForEach(Array(zip(panels, display.panelDisplays).enumerated()), id: \.offset) { _, pair in
                        let (panel, shown) = pair
                        WallpaperFill(image: Wallpaper.image(for: shown), cornerRadius: 3)
                            .frame(width: panel.width * width, height: panel.height * height)
                            .offset(x: panel.minX * width, y: panel.minY * height)
                    }
                }
                ForEach(space.windows) { window in
                    tile(window, in: CGSize(width: width, height: height))
                }
            }
            // Fixed to the card, so a tile bigger than it can't grow the clip along with it
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            // The current Desktop has a white ring, as Mission Control marks it; accent is kept for drop targets
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(space.isCurrent ? Color.white : .secondary.opacity(0.3), lineWidth: space.isCurrent ? 2.5 : 0.5))
            .overlay { if space.isCurrent { RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.25), lineWidth: 0.5) } }
            .overlay { if empty { RoundedRectangle(cornerRadius: 5).fill(.background.opacity(0.45)) } }
            .contentShape(Rectangle())
            .onTapGesture {
                Spaces.switchTo(space.id)
                close()
            }
            .overlay {
                // Where a dragged window would go: outlined, tinted and labelled
                if dropTarget == space.id {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2.5))
                        // At the bottom edge, clear of the dragged icon under the pointer
                        .overlay(alignment: .bottom) {
                            Text("Move Here").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                                .padding(.bottom, 3)
                        }
                }
            }
            .dropDestination(for: String.self) { items, location in
                dropTarget = nil
                // On a card covering several displays, the panel dropped on picks the display
                let point = CGPoint(x: location.x / width, y: location.y / height)
                let panel = panels.firstIndex { $0.contains(point) }.flatMap { space.panelSpaces.indices.contains($0) ? space.panelSpaces[$0] : nil }
                for item in items { WindowID(item).map { model.send($0, to: panel ?? space.id, keepingDisplay: panel == nil) } }
                return !items.isEmpty
            } isTargeted: { over in
                if over { dropTarget = space.id } else if dropTarget == space.id { dropTarget = nil }
            }
            .help([String(space.number), space.label].compactMap { $0 }.joined(separator: " ") + (empty ? ", empty" : ""))
            // The current Desktop's number is a filled badge, so where you are is plain at a glance
            Text([String(space.number), space.label].compactMap { $0 }.joined(separator: " "))
                .font(.caption2.weight(space.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(space.isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, space.isCurrent ? 6 : 0).padding(.vertical, space.isCurrent ? 1 : 0)
                .background { if space.isCurrent { Capsule().fill(Color.accentColor) } }
                .frame(maxWidth: max(width, 40))
        }
    }

    private func tile(_ window: WindowManager.MiniWindow, in size: CGSize) -> some View {
        // Only the part of the window on the display, so a window hanging off the edge stays in its card
        let visible = window.rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let shown = visible.isNull ? .zero : visible
        let rect = CGRect(x: shown.minX * size.width, y: shown.minY * size.height,
                          width: max(shown.width * size.width, 8), height: max(shown.height * size.height, 8))
        let icon = NSRunningApplication(processIdentifier: window.pid)?.icon
        // Floating windows get a dashed accent outline and the float symbol, so a window that
        // isn't tiling doesn't look like a tiling bug
        let preview = WindowPreviews.shared.images[window.id]
        return RoundedRectangle(cornerRadius: 3)
            .fill(.background)
            .overlay {
                // The window's content when previews are on, cropped to its tile
                if let preview {
                    Color.clear
                        .overlay { Image(decorative: preview, scale: 2).resizable().aspectRatio(contentMode: .fill) }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                window.isFloating || hovered == window.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.5)),
                style: StrokeStyle(lineWidth: window.isFloating || hovered == window.id ? 1.5 : 1,
                                   dash: window.isFloating && hovered != window.id ? [3, 2] : [])))
            .overlay(alignment: preview == nil ? .center : .bottomTrailing) {
                // Over a preview the icon shrinks to a badge, so the content shows
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit().padding(2)
                        .frame(maxWidth: preview == nil ? 20 : 14, maxHeight: preview == nil ? 20 : 14)
                        .shadow(radius: preview == nil ? 0 : 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if window.isFloating {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tint).padding(2)
                }
            }
            .help((window.isFloating ? "Floating: not tiled." + (model.shortcut(for: "float").map { " \($0) tiles it again." } ?? "") + " " : "")
                  + "Click to go to it, or drag it onto another Desktop to send it there.")
            .accessibilityLabel((NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "Window") + (window.isFloating ? ", floating" : ""))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            // An open hand says it can be picked up
            .pointerStyle(.grabIdle)
            .onHover { inside in
                if inside { hovered = window.id } else if hovered == window.id { hovered = nil }
            }
            .onTapGesture {
                model.manager.show(window.id)
                close()
            }
            .draggable(String(window.id)) {
                // Just the app's icon, small: the cards are small, and the one under the pointer and
                // its highlight have to stay in view
                icon.map { Image(nsImage: $0).resizable().frame(width: 24, height: 24) }
            }
    }
}

/// Spacetile's name and the switch that pauses it, as Wi-Fi and Bluetooth head their menus, with
/// anything that needs attention underneath.
private struct MiniMapHeader: View {
    var model: MiniMapModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Name, a one-line status and the switch, as Wi-Fi and Ollama head their menus. The status
            // is always there, so switching doesn't move anything
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Spacetile").font(.headline)
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(status)
                }
                Spacer()
                Toggle("Tiling", isOn: Binding(get: { !model.status.paused }, set: { _ in model.manager.perform(.togglePause) }))
                    .toggleStyle(MenuSwitchStyle())
                    .disabled(model.accessibilityLost)
                    .help("Off pauses tiling: Spacetile moves no windows and releases every shortcut except Pause"
                          + (model.shortcut(for: "pause").map { " (\($0))" } ?? ""))
            }
            if model.accessibilityLost {
                MenuRow(title: "Grant Accessibility…", symbol: "exclamationmark.triangle.fill", tint: .orange) { run(model.showWelcome, close) }
                    .help("Accessibility was turned off, so tiling is paused. Spacetile restarts once it's back on.")
                    .padding(.horizontal, -8)
            }
            if let error = model.configError {
                MenuRow(title: error, symbol: "exclamationmark.triangle.fill", tint: .orange) { run({ NSWorkspace.shared.open(ConfigStore.file) }, close) }
                    .help("Open config.json to fix it. Spacetile keeps using the last good settings.")
                    .padding(.horizontal, -8)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var status: String {
        if model.accessibilityLost { return "Needs Accessibility permission" }
        guard model.status.paused else { return "Tiling windows as they open" }
        return "Paused: windows stay put; only " + (model.shortcut(for: "pause").map { "Pause (\($0))" } ?? "Pause") + " works"
    }
}

/// Profiles and the app, laid out like a menu: icon, title, shortcut. Everyday commands like
/// retiling and layout modes are left to their shortcuts.
private struct MiniMapFooter: View {
    var model: MiniMapModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Profiles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 4)
            // One click applies; the one applied last is ticked
            ForEach(model.profiles, id: \.name) { profile in
                Button {
                    close()
                    model.manager.perform(.load(profile.name))
                } label: {
                    MenuRowLabel(title: profile.name, symbol: profile.symbol, shortcut: model.shortcut(for: "load \(profile.name)"),
                                 tint: nil, trailing: model.manager.lastProfile == profile.name ? "checkmark" : nil)
                }
                .buttonStyle(MenuRowStyle())
                .disabled(model.status.paused)
                .help(profile.autoApply == true ? "Applies by itself when its displays are connected" : "Apply this profile")
            }
            // A file with a typo shows here disabled rather than vanishing; the Profiles window says why
            ForEach(model.profileProblems, id: \.file) { problem in
                MenuRowLabel(title: "\(problem.file.deletingPathExtension().lastPathComponent) didn't load", symbol: "exclamationmark.triangle",
                             shortcut: nil, tint: .orange, trailing: nil)
                    .help(problem.message)
            }
            MenuRow(title: "Save Current Layout…", symbol: "plus") { run(model.captureLayout, close) }
                .help("Save how every Desktop looks now as a profile, to apply again later")
            MenuRow(title: "Edit Profiles…", symbol: "square.and.pencil", shortcut: "⇧⌘P") { run(model.editProfiles, close) }
            Divider().padding(.vertical, 4)
            MenuRow(title: "Check for Updates…", symbol: "arrow.triangle.2.circlepath") { run(model.checkForUpdates, close) }
            MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { run(model.openSettings, close) }
            MenuRow(title: "Quit Spacetile", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(6)
    }
}

/// Closes the popover first, so alerts and windows the action opens aren't hidden behind it.
private func run(_ action: @escaping () -> Void, _ close: () -> Void) {
    close()
    Task { action() }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, symbol: symbol, shortcut: shortcut, tint: tint, trailing: nil)
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// The 30×16 switch menu extras like Ollama head their menus with. SwiftUI's switch here ignores
/// `controlSize` and `scaleEffect`, and takes a focus ring.
private struct MenuSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5).padding(1.5)
            }
            .frame(width: 30, height: 16)
            .animation(.snappy(duration: 0.15), value: configuration.isOn)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct MenuRowLabel: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let tint: Color?
    let trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            Text(title).lineLimit(2)
            Spacer(minLength: 16)
            if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            if let trailing { Image(systemName: trailing).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Highlights on hover like a menu item.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering || configuration.isPressed ? Color.primary.opacity(0.1) : .clear))
        }
    }
}

private struct Hovering<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content(hovering && isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

/// Runs the closure an item carries in `representedObject`. One shared target, since menu items
/// hold their target weakly.
final class ClosureMenuTarget: NSObject {
    static let shared = ClosureMenuTarget()

    static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = shared
        item.representedObject = run
        return item
    }

    @objc private func fire(_ item: NSMenuItem) { (item.representedObject as? () -> Void)?() }
}
