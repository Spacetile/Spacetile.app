import AppKit
import SpacetileCore
import SwiftUI

/// First-run guide: why Spacetile needs Accessibility and a button that asks for it, the macOS
/// settings it relies on, whose shortcuts to start from, then the few worth learning first. Shown on first launch and
/// whenever Accessibility is missing; Settings › Permissions & macOS brings it back.
final class Welcome {
    static let seenKey = "welcomeSeen"
    private let model: WelcomeModel
    private var refresh: Timer?

    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(model: model)))
        window.title = "Welcome to Spacetile"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        // Checks only change while someone is looking at them, so poll only then
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRefreshing() }
        }
        return window
    }()

    init(settings: @escaping () -> SpacetileCore.Settings, saveKeys: @escaping ([String: String]) -> Void) {
        model = WelcomeModel(settings: settings)
        model.saveKeys = saveKeys
        model.close = { [weak self] in self?.window.close() }
    }

    func show(page: WelcomeModel.Page? = nil) {
        model.refresh()
        model.page = page ?? (model.trusted ? .macOS : .permission)
        DockPresence.show(window)
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [model] _ in
            MainActor.assumeIsolated { model.refresh() }
        }
        refresh?.tolerance = 0.3
    }

    /// Development aid for `spacetile-ctl welcome-shot <permission|macOS|presets|keys> <path>`, rendered by
    /// SwiftUI like the mini-map snapshot.
    func snapshot(page: String, to path: String) {
        model.refresh()
        model.page = ["permission": .permission, "macOS": .macOS, "presets": .presets, "keys": .keys][page] ?? .permission
        let renderer = ImageRenderer(content: WelcomeView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation else { return }
        try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func stopRefreshing() {
        refresh?.invalidate()
        refresh = nil
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }
}

@Observable final class WelcomeModel {
    enum Page { case permission, macOS, presets, keys }

    var page = Page.permission
    var trusted = AXIsProcessTrusted()
    var checks: [SetupCheck] = []
    let settings: () -> SpacetileCore.Settings
    var close: () -> Void = {}
    var saveKeys: ([String: String]) -> Void = { _ in }
    /// The shortcuts chosen on the presets page; nil is Spacetile's own.
    var preset: KeyPreset?
    /// Only a choice made on the page changes shortcuts, so passing through the guide again keeps
    /// ones the user recorded.
    var chosePreset = false

    /// Puts the chosen shortcuts in place, unless they're the ones in use already.
    func applyPreset() {
        guard chosePreset else { return }
        let keys = preset?.settingsKeys ?? SpacetileCore.Settings.default.keys
        if settings().keys != keys { saveKeys(keys) }
    }

    init(settings: @escaping () -> SpacetileCore.Settings) { self.settings = settings }

    func refresh() {
        trusted = AXIsProcessTrusted()
        checks = SetupCheck.all(spaceCount: Spaces.mostDesktops).filter { $0.id != SetupCheck.accessibilityID }
    }

    /// Adds Spacetile to the Accessibility list with the system prompt, and opens the pane where the switch is.
    func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let pane = URL(string: SetupCheck.accessibilityPane) { NSWorkspace.shared.open(pane) }
    }

    func keys(for commands: [String]) -> String? { settings().shortcutText(commands) }
}

struct WelcomeView: View {
    var model: WelcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.page {
            case .permission: permission
            case .macOS: macOS
            case .presets: presets
            case .keys: keys
            }
        }
        .padding(24)
        .frame(width: 560, height: 460, alignment: .topLeading)
    }

    private var permission: some View {
        Group {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                Text("Welcome to Spacetile").font(.title2.weight(.semibold))
            }
            Text("Spacetile tiles your windows on macOS's own Spaces, and moves them between Spaces with the keyboard and mouse.")
            Text("To move and resize other apps' windows it needs Accessibility permission. It reads each window's title, position and size, never what's in it unless you turn on window previews in Settings.")
                .foregroundStyle(.secondary)
            Label(model.trusted ? "Accessibility is on" : "Waiting for Accessibility permission…",
                  systemImage: model.trusted ? "checkmark.circle.fill" : "hourglass")
                .foregroundStyle(model.trusted ? .green : .secondary)
            if !model.trusted {
                Text("Click the button, then turn on Spacetile in the list that opens. This window notices when you do.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            footer {
                if model.trusted {
                    Button("Continue") { model.page = .macOS }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Accessibility Settings…") { model.requestAccess() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var macOS: some View {
        Group {
            heading("Check your macOS settings", symbol: "gearshape.2")
            Text("A few macOS settings change how Spaces behave. Fix any marked here; you can change them later in Settings › Permissions & macOS.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.checks) { SetupCheckRow(check: $0) }
                }
            }
            footer {
                Button("Continue") { model.page = .presets }.keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Spacetile's own shortcuts, or another window manager's for people moving over.
    private var presets: some View {
        Group {
            heading("Choose your shortcuts", symbol: "command")
            Text("Coming from another window manager? Start from its shortcuts. Spacetile's own fill in everything it doesn't have. You can switch any time in Settings › Keys.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    presetRow(nil, title: "Spacetile", detail: "⌥ to focus and switch Spaces, ⌥⇧ to move, ⌥⌃ to place and size.")
                    ForEach(KeyPreset.all) { presetRow($0, title: $0.name, detail: $0.note) }
                }
            }
            footer {
                Button("Continue") {
                    model.applyPreset()
                    model.page = .keys
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func presetRow(_ preset: KeyPreset?, title: String, detail: String) -> some View {
        let chosen = model.preset?.id == preset?.id
        return Button {
            model.preset = preset
            model.chosePreset = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quinary), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var keys: some View {
        Group {
            heading("Five shortcuts to start with", symbol: "keyboard")
            VStack(alignment: .leading, spacing: 10) {
                shortcut("Focus the window to the left, below, above or right", ["focus west", "focus south", "focus north", "focus east"])
                shortcut("Switch to a Space", (1...9).map { "space \($0)" })
                shortcut("Send the focused window to a Space", (1...9).map { "send \($0)" })
                shortcut("Float or tile the focused window", ["float"])
                shortcut("Pause or resume tiling", ["pause"])
            }
            Text("Every action and its keys are in Settings › Keys. Click the menu-bar item for a map of your Spaces and the rest of Spacetile's actions.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            footer {
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.title2.weight(.semibold)).labelStyle(.titleAndIcon)
    }

    private func shortcut(_ title: String, _ commands: [String]) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let keys = model.keys(for: commands) {
                Keycap(text: keys, dimmed: false)
            } else {
                Text("No shortcut yet; set one in Settings › Keys").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Skip on the left, the page's next step on the right.
    private func footer<Next: View>(@ViewBuilder next: () -> Next) -> some View {
        HStack {
            if model.page != .keys {
                Button("Skip") { model.close() }
                    .help(model.trusted ? "Close this guide" : "Close this guide; Spacetile starts as soon as Accessibility is on")
            }
            Spacer()
            next()
        }
    }
}
