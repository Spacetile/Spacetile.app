import AppKit
import os
import ServiceManagement
import SpacetileCore

let log = Logger(subsystem: "com.kodehort.spacetile", category: "wm")
/// Intervals for Instruments' os_signpost track: layout passes, Space changes and switches, profile loads.
let signposter = OSSignposter(subsystem: "com.kodehort.spacetile", category: "performance")

/// Menu bar agent: shows the current Space number and owns the window manager.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let manager = WindowManager()
    private let config = ConfigStore()
    private var hotkeys: Hotkeys?
    private var mouse: Mouse?
    private var settingsWindow: SettingsWindow?
    private var miniMap: MiniMap?
    private var spacesWindow: SpacesWindow?
    private let updates = Updates()
    private var status = WindowManager.Status()
    private lazy var welcome = Welcome(settings: { [config] in config.settings }, saveKeys: { [config] keys in
        var settings = config.settings
        settings.keys = keys
        config.save(settings)
    })
    /// Accessibility was revoked while running. Tiling pauses, and Spacetile relaunches once it's
    /// granted again, since the event tap and AX observers don't survive the revocation.
    private var accessibilityLost = false

    func applicationDidFinishLaunching(_: Notification) {
        // Before the Accessibility wait, so a build that can't get the grant can still be replaced
        updates.start()
        NSApp.mainMenu = mainMenu()
        statusItem.button?.image = Self.symbol("square.grid.2x2", "Spacetile")
        // Any click opens the mini-map, whose footer has everything a menu would
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        manager.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.status = status
            self.hotkeys?.paused = status.paused
            self.miniMap?.model.status = status
            self.updateTitle()
        }
        if !UserDefaults.standard.bool(forKey: Welcome.seenKey) || !AXIsProcessTrusted() { welcome.show() }
        manager.confirmModeMismatch = { profile, spansNow in Self.confirmModeMismatch(profile, spansNow: spansNow) }
        manager.onProfileWarning = { profile, unplaced in
            // After the load finishes, so the warning doesn't hold it up
            DispatchQueue.main.async { Self.warnUnplaced(profile, unplaced) }
        }
        startWhenTrusted()
    }

    /// Asks before applying a profile captured in the other Spaces mode.
    private static func confirmModeMismatch(_ profile: Profile, spansNow: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(profile.name)” was captured with " + (spansNow ? "each display having its own Spaces" : "Spaces spanning displays")
        alert.informativeText = (spansNow ? "Spaces span displays now (Displays have separate Spaces is off)." : "Each display has its own Spaces now (Displays have separate Spaces is on).")
            + " Its Spaces may land on different Desktops than when it was captured, and any whose Desktop doesn't exist are skipped."
        alert.addButton(withTitle: "Apply Anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Says which of a profile's Spaces had no Desktop to go to, and how to make room.
    private static func warnUnplaced(_ profile: Profile, _ unplaced: [ProfilePlacement]) {
        let byDisplay = Dictionary(grouping: unplaced) { $0.display?.name ?? "the display" }
        let lines = byDisplay.map { name, placements in
            "\(name) has no Desktop \(placements.map { String($0.number) }.joined(separator: ", "))."
        }.sorted()
        let alert = NSAlert()
        alert.messageText = "“\(profile.name)” couldn't place \(unplaced.count) Space\(unplaced.count == 1 ? "" : "s")"
        alert.informativeText = lines.joined(separator: "\n")
            + "\n\nThose windows stay where they are. Add Desktops in Mission Control (⌃↑, then +) and apply the profile again."
        NSApp.activate()
        alert.runModal()
    }

    /// Opening Spacetile again from Finder, Spotlight or Raycast shows Settings, so the app stays
    /// reachable when macOS hides its menu-bar item.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        openSettings()
        return false
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    /// An accessory app never draws its main menu, but key equivalents still route through it:
    /// without Edit and Window menus, ⌘C/⌘V/⌘Z and ⌘W do nothing in the Settings window.
    private func mainMenu() -> NSMenu {
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu?.addItem($0) }
            return item
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let settings = item("Settings…", #selector(openSettings), ",")
        settings.target = self
        let profiles = item("Profiles", #selector(openProfiles), "p", [.command, .shift])
        profiles.target = self
        let spaces = item("Spaces", #selector(openSpaces), "")
        spaces.target = self
        let welcome = item("Welcome Guide", #selector(showWelcome), "")
        welcome.target = self
        let checkForUpdates = item("Check for Updates…", #selector(checkForUpdates), "")
        checkForUpdates.target = self
        let menu = NSMenu()
        menu.addItem(submenu("Spacetile", [
            item("About Spacetile", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            checkForUpdates,
            .separator(),
            settings,
            .separator(),
            item("Quit Spacetile", #selector(NSApplication.terminate), "q"),
        ]))
        menu.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut), "x"),
            item("Copy", #selector(NSText.copy), "c"),
            item("Paste", #selector(NSText.paste), "v"),
            item("Select All", #selector(NSText.selectAll), "a"),
        ]))
        menu.addItem(submenu("Window", [
            item("Close", #selector(NSWindow.performClose), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize), "m"),
            .separator(),
            spaces,
            profiles,
        ]))
        menu.addItem(submenu("Help", [welcome]))
        return menu
    }

    /// Accessibility is granted in System Settings while the app keeps running, so check every
    /// second until it is. The Welcome window asks for it; this only notices.
    private func startWhenTrusted(waiting: Bool = false) {
        guard AXIsProcessTrusted() else {
            if !waiting { log.notice("waiting for accessibility permission") }
            statusItem.button?.image = Self.symbol("exclamationmark.triangle", "Spacetile needs Accessibility permission")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startWhenTrusted(waiting: true) }
            return
        }
        log.notice("accessibility trusted, starting")
        manager.start()
        mouse = Mouse(manager: manager)
        mouse?.onDisabled = { [weak self] in self?.checkAccessibility() }
        watchAccessibility()
        hotkeys = Hotkeys { [weak self] command in
            log.notice("command \(command.text, privacy: .public)")
            self?.run(command)
        }
        config.onChange = { [weak self] config in
            guard let self else { return }
            self.manager.update(config.settings)
            WindowPreviews.shared.enabled = config.settings.showsWindowPreviews
            self.hotkeys?.rebind(config.settings)
            self.miniMap?.model.settings = config.settings
            self.miniMap?.model.configError = config.error
            self.updateTitle()
            self.settingsWindow?.configChanged()
        }
        miniMap = MiniMap(manager: manager,
                          captureLayout: { [weak self] in self?.captureLayout() },
                          editProfiles: { [weak self] in self?.openProfiles() },
                          openSettings: { [weak self] in self?.openSettings() },
                          showWelcome: { [weak self] in self?.welcome.show() },
                          openSpaces: { [weak self] in self?.openSpaces() },
                          checkForUpdates: { [weak self] in self?.checkForUpdates() })
        config.start()
        WindowPreviews.shared.enabled = config.settings.showsWindowPreviews
        FocusFilterRouter.handler = { [manager] in manager.perform(.load($0)) }
        settingsWindow = hotkeys.map {
            SettingsWindow(config: config, hotkeys: $0, manager: manager,
                           showWelcome: { [weak self] in self?.welcome.show() },
                           checkForUpdates: { [weak self] in self?.checkForUpdates() })
        }
        // Commands from scripts and other key binders: `scripts/spacetile-ctl focus west`
        DistributedNotificationCenter.default().addObserver(forName: .init("com.kodehort.spacetile.command"), object: nil, queue: .main) { [weak self] note in
            guard let text = note.object as? String else { return }
            MainActor.assumeIsolated { self?.remote(text) }
        }
    }

    /// Runs a command sent by `spacetile-ctl`. Release builds take only `settings` and the
    /// commands in https://spacetile.app/docs/commands/; the development aids need `scripts/bundle.sh --dev`.
    private func remote(_ text: String) {
        #if SPACETILE_DEV
        if developmentAid(text.split(separator: " ").map(String.init)) { return }
        #endif
        guard let command = Command(text) else { return log.notice("unknown remote command \(text, privacy: .public)") }
        log.notice("remote command \(text, privacy: .public)")
        run(command)
    }

    /// Commands about the app itself run here; the rest go to the window manager.
    private func run(_ command: Command) {
        if command == .openSettings { return openSettings() }
        if case .toggle(let setting) = command {
            // Saving over a config.json that doesn't parse would lose the hand edits in it
            guard config.error == nil else { return log.error("\(command.text, privacy: .public): config.json has an error, not saving") }
            var settings = config.settings
            settings.flip(setting)
            return config.save(settings)
        }
        guard checkAccessibility() else { return }
        manager.perform(command)
    }

    /// Checked every second, and whenever Spacetile is about to act (a command, a click on the
    /// menu-bar item, the mouse tap switching off). Returns whether Accessibility is still on.
    @discardableResult private func checkAccessibility() -> Bool {
        guard miniMap != nil, !AXIsProcessTrusted() else { return true }
        guard !accessibilityLost else { return false }
        log.error("accessibility was turned off; removing the mouse tap and pausing")
        accessibilityLost = true
        mouse?.stop()
        mouse = nil
        if !manager.isPaused { manager.perform(.togglePause) }
        miniMap?.model.accessibilityLost = true
        updateTitle()
        welcome.show()
        relaunchWhenTrusted()
        return false
    }

    /// Notices Accessibility being revoked within a second, so the mouse tap goes before it can
    /// hold up input.
    private func watchAccessibility() {
        guard checkAccessibility() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.watchAccessibility() }
    }

    private func relaunchWhenTrusted() {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.relaunchWhenTrusted() }
            return
        }
        log.notice("accessibility back on; relaunching")
        // The new copy waits for this one to quit, or the single-instance check would stop it
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    #if SPACETILE_DEV
    /// Returns true if `words` was a development aid.
    private func developmentAid(_ words: [String]) -> Bool {
        switch (words.first, words.count) {
        case ("login", 2) where words[1] == "on":
            do { try SMAppService.mainApp.register() } catch { log.error("login item: \(error.localizedDescription, privacy: .public)") }
            log.notice("login item status \(SMAppService.mainApp.status.rawValue)")
        // Runs focus-follows-mouse for that point
        case ("hover", 3):
            guard let x = Double(words[1]), let y = Double(words[2]) else { return false }
            _ = manager.window(at: CGPoint(x: x, y: y)).map(manager.focusUnderMouse)
        // Toggles native full screen on that app's focused window, e.g. `fullscreen Zed Preview`;
        // `fullscreen pair` is the command
        case ("fullscreen", 2...) where words != ["fullscreen", "pair"]:
            let name = words.dropFirst().joined(separator: " ")
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
                  let window: AXUIElement = AXUIElementCreateApplication(app.processIdentifier).value(of: kAXFocusedWindowAttribute) else { return true }
            let on = window.value(of: "AXFullScreen") != true
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, on as CFBoolean)
        case ("overlay-preview", 2):
            Overlay.preview(to: words[1])
        // Makes Settings act as if there were N Spaces (0 clears)
        case ("spaces-override", 2):
            SettingsModel.spaceCountOverride = Int(words[1]).flatMap { $0 > 0 ? $0 : nil }
        // Saves the menu-bar item's image
        case ("menubar-shot", 2):
            guard let image = statusItem.button?.image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return true }
            try? png.write(to: URL(fileURLWithPath: words[1]))
        // Opens or closes the mini-map as clicking the menu-bar item does
        case ("minimap", 1):
            statusItem.button.map { miniMap?.toggle(from: $0) }
        case ("minimap-shot", 2):
            guard let button = statusItem.button else { return true }
            miniMap?.snapshot(from: button, to: words[1])
        // What clicking a window in the mini-map does: switch to its Space, on any display, and focus it
        // Measures a window's real minimum size: asks for 300×300, reads it back twice, then retiles
        case ("min-size", 2):
            guard let id = WindowID(words[1]) else { return false }
            manager.measureMinimumSize(of: id)
        case ("show", 2):
            guard let id = WindowID(words[1]) else { return false }
            manager.show(id)
        // Runs the wake handler, for testing without sleeping the Mac
        case ("wake", 1):
            manager.displaysChanged("woke (dev aid)")
        case ("welcome-shot", 3):
            welcome.snapshot(page: words[1], to: words[2])
        case ("settings-shot", 3):
            settingsWindow?.snapshot(tab: words[1], to: words[2])
        default:
            return false
        }
        return true
    }
    #endif

    /// Draws the menu-bar item from the Menu Bar settings; a ⚠︎ leads when config.json has an error.
    private func updateTitle() {
        let image = MenuBarRenderer.image(for: status, settings: config.settings.menuBarSettings, warning: config.error != nil || accessibilityLost)
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? (status.space.map(String.init) ?? "·") : ""
        // The image says nothing to VoiceOver, so name what it shows
        let parts = ["Spacetile", accessibilityLost ? "needs Accessibility permission" : nil, status.paused ? "paused" : nil,
                     status.space.map { "Space \($0)" }, status.label, status.profile.map { "profile \($0)" },
                     config.error.map { _ in "config.json has an error" }]
        statusItem.button?.setAccessibilityLabel(parts.compactMap { $0 }.joined(separator: ", "))
    }

    @objc private func statusItemClicked(_ button: NSStatusBarButton) {
        checkAccessibility()
        if let miniMap { return miniMap.toggle(from: button) }
        // Nothing runs until Accessibility is granted, so offer the way there instead
        let menu = NSMenu()
        menu.addItem(withTitle: "Spacetile needs Accessibility permission", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Set Up Accessibility…", action: #selector(showWelcome), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Spacetile", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        // Attach the menu only for this click, so later clicks keep reaching this action
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showWelcome() { welcome.show() }

    @objc private func openSettings() { settingsWindow?.show() }

    @objc private func checkForUpdates() { updates.check() }

    @objc private func openProfiles() { settingsWindow?.showProfiles() }

    @objc private func openSpaces() {
        guard let miniMap else { return }
        if spacesWindow == nil { spacesWindow = SpacesWindow(model: miniMap.model) }
        spacesWindow?.show()
    }

    /// Asks whether to save into the profile applied last or as a new one, then saves every Space's
    /// arrangement. A new one asks for a name, suggesting the current display's; typing an existing
    /// profile's name turns Capture into Replace, which keeps that profile's settings.
    private func captureLayout() {
        let profiles = ProfileStore.all
        if let current = manager.lastProfile.flatMap({ name in profiles.first { $0.name == name } }) {
            switch Self.askSaveTarget(current) {
            case .alertFirstButtonReturn: return manager.recapture(current, makeCurrent: true)
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        let alert = NSAlert()
        alert.messageText = "Capture Layout"
        alert.informativeText = "Saves every Space's windows and tiling. A profile loads by itself when the display it was captured on becomes the main display."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let display = (NSScreen.main?.localizedName ?? "profile").lowercased()
        field.stringValue = uniqueProfileName(display, taken: Set(profiles.map(\.name)))
        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 240
        let stack = NSStackView(views: [field, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 64)
        alert.accessoryView = stack
        let capture = alert.addButton(withTitle: "Capture")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        // Main-actor closures rather than local functions, so the text-change observer below can call update()
        let name: @MainActor () -> String = { field.stringValue.trimmingCharacters(in: .whitespaces) }
        // Matched by file, since names differing only by / and - share one
        let existing: @MainActor () -> Profile? = { profiles.first { profileFileName($0.name) == profileFileName(name()) } }
        let update: @MainActor () -> Void = {
            capture.title = existing() == nil ? "Capture" : "Replace"
            capture.isEnabled = !name().isEmpty
            note.stringValue = existing().map { "Replaces the windows and layouts in “\($0.name)”. Its other settings stay." } ?? ""
        }
        update()
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, !name().isEmpty else { return }
        if let profile = existing() { manager.recapture(profile, makeCurrent: true) } else { manager.capture(name(), makeCurrent: true) }
    }

    /// Update the profile applied last (first button), save a new one (second), or cancel.
    private static func askSaveTarget(_ current: Profile) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: current.symbol, accessibilityDescription: current.name)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
        alert.messageText = "Save to “\(current.name)”?"
        alert.informativeText = "“\(current.name)” is the profile applied last. Saving to it replaces its windows and layouts with how every Desktop looks now; its icon, shortcut and other settings stay. Or save the layout as a new profile."
        alert.addButton(withTitle: "Save to “\(current.name)”")
        alert.addButton(withTitle: "New Profile…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal()
    }
}

/// Hands a command to the running copy, as `spacetile-ctl` does.
func postCommand(_ text: String) {
    DistributedNotificationCenter.default().postNotificationName(.init("com.kodehort.spacetile.command"), object: text, deliverImmediately: true)
}

// Run from a shell, skhd or Karabiner (`spacetile focus west`): pass the command on and exit.
// Launch Services and Xcode add `-…` flags, which aren't commands.
let arguments = CommandLine.arguments.dropFirst()
if let first = arguments.first, !first.hasPrefix("-") {
    postCommand(arguments.joined(separator: " "))
    exit(0)
}

// A second copy would fight the first over every window, so hand over to the running one: it opens
// Settings, which is what launching the app again usually means
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    log.notice("already running, opening its Settings")
    postCommand("settings")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
