import AppKit
import ServiceManagement
import SpacetileCore
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window, a front end for config.json plus read-only checks of the macOS settings
/// Spacetile depends on, and the Profiles window, which shares its model. Every change is written
/// straight to config.json (or the profile's file), which applies it.
final class SettingsWindow {
    private let model: SettingsModel
    private lazy var undoSource = UndoSource(undo: model.undo)
    private static let paneKey = "settingsPane"

    /// Toolbar panes, General first and the checks last, each sized to its content.
    private static let panes: [(tag: String, title: String, symbol: String, size: CGSize)] = [
        ("General", "General", "gearshape", CGSize(width: 620, height: 600)),
        ("Keys", "Keys", "keyboard", CGSize(width: 700, height: 640)),
        ("Rules", "Rules", "list.bullet.rectangle", CGSize(width: 640, height: 600)),
        ("Spaces", "Spaces", "rectangle.3.group", CGSize(width: 620, height: 480)),
        ("MenuBar", "Menu Bar", "menubar.rectangle", CGSize(width: 620, height: 640)),
        ("Setup", "Permissions & macOS", "checkmark.shield", CGSize(width: 620, height: 560)),
    ]

    private lazy var panes: PaneController = {
        let controller = PaneController()
        controller.tabStyle = .toolbar
        let model = self.model
        for pane in Self.panes {
            let hosting = NSHostingController(rootView: AnyView(PaneView(model: model) { AnyView(Self.content(pane.tag, model: model)) }
                .frame(width: pane.size.width, height: pane.size.height)))
            hosting.sizingOptions = []
            // The tab controller titles the window from the selected pane's controller
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = pane.tag
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            controller.addTabViewItem(item)
        }
        controller.onSelect = { [weak self] tag in self?.selected(tag) }
        return controller
    }()

    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: panes)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = undoSource
        // Spaces may have been added in Mission Control since the window was last in front
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.refresh() }
        }
        return window
    }()

    private lazy var profilesWindow: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: AnyView(ProfilesTab(model: model).frame(minWidth: 820, minHeight: 560))))
        window.title = "Profiles"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 660))
        window.setFrameAutosaveName("Profiles")
        window.isReleasedWhenClosed = false
        window.delegate = undoSource
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.refresh() }
        }
        return window
    }()

    @ViewBuilder private static func content(_ tag: String, model: SettingsModel) -> some View {
        switch tag {
        case "Keys": KeysTab(model: model)
        case "Rules": RulesTab(model: model)
        case "Spaces": SpacesTab(model: model)
        case "MenuBar": MenuBarTab(model: model)
        case "Setup": SetupTab(model: model)
        default: GeneralTab(model: model)
        }
    }

    init(config: ConfigStore, hotkeys: Hotkeys, manager: WindowManager, showWelcome: @escaping () -> Void,
         checkForUpdates: @escaping () -> Void) {
        model = SettingsModel(config: config, hotkeys: hotkeys, manager: manager)
        model.showWelcome = showWelcome
        model.checkForUpdates = checkForUpdates
        model.showProfiles = { [weak self] in self?.showProfiles() }
        model.didRefresh = { [weak self] in self?.updateChecksPane() }
    }

    /// Opens on the last pane used, unless a check needs attention.
    func show(pane: String? = nil) {
        model.refresh()
        let wasVisible = window.isVisible
        if let pane {
            select(pane)
        } else if !wasVisible {
            select(model.problemCount > 0 ? "Setup" : UserDefaults.standard.string(forKey: Self.paneKey) ?? "General")
        }
        if !wasVisible { window.center() }
        DockPresence.show(window)
    }

    func showProfiles() {
        model.refresh()
        if !profilesWindow.isVisible, !profilesWindow.setFrameUsingName("Profiles") { profilesWindow.center() }
        DockPresence.show(profilesWindow)
    }

    /// Called when config.json changes underneath an open window.
    func configChanged() { model.refresh() }

    private func select(_ tag: String) {
        guard let index = Self.panes.firstIndex(where: { $0.tag == tag }) else { return }
        if panes.selectedTabViewItemIndex == index { selected(tag) } else { panes.selectedTabViewItemIndex = index }
    }

    /// Titles the window after the pane, sizes it to fit (keeping the top edge where it was) and
    /// remembers the pane for next time.
    private func selected(_ tag: String) {
        guard let pane = Self.panes.first(where: { $0.tag == tag }) else { return }
        model.tab = tag
        if tag != "Setup" { UserDefaults.standard.set(tag, forKey: Self.paneKey) }
        window.title = panes.tabViewItems.first { $0.identifier as? String == tag }?.label ?? pane.title
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    /// The checks pane counts what needs attention in its toolbar label.
    private func updateChecksPane() {
        guard let item = panes.tabViewItems.first(where: { $0.identifier as? String == "Setup" }) else { return }
        let count = model.problemCount
        item.label = count > 0 ? "Permissions & macOS (\(count))" : "Permissions & macOS"
        item.viewController?.title = item.label
        item.image = NSImage(systemSymbolName: count > 0 ? "exclamationmark.shield" : "checkmark.shield", accessibilityDescription: item.label)
        if model.tab == "Setup" { window.title = item.label }
    }

    /// Development aid for `spacetile-ctl settings-shot <pane> <path>`: shows a pane (or `Profiles`)
    /// and saves the window's contents as a PNG, which needs no screen-recording permission.
    /// `Keys@3000`-style names capture a taller window so long panes fit.
    func snapshot(tab: String, to path: String) {
        let name = String(tab.split(separator: "@")[0])
        let target: NSWindow
        if name == "Profiles" {
            showProfiles()
            target = profilesWindow
        } else {
            show(pane: name)
            target = window
        }
        if let height = tab.split(separator: "@").dropFirst().first.flatMap({ Double($0) }) {
            target.setFrame(NSRect(x: 0, y: 0, width: target.frame.width, height: height), display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let view = target.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Hands both windows the model's undo manager, which is how Edit › Undo reaches it.
private final class UndoSource: NSObject, NSWindowDelegate {
    let undo: UndoManager

    init(undo: UndoManager) { self.undo = undo }

    func windowWillReturnUndoManager(_: NSWindow) -> UndoManager? { undo }
}

/// Reports pane changes; the window does the rest.
private final class PaneController: NSTabViewController {
    var onSelect: (String) -> Void = { _ in }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        (item?.identifier as? String).map(onSelect)
    }
}

/// Spacetile has no Dock icon until one of its windows is open. Then it joins the Dock and ⌘Tab
/// and shows its menu bar like any app, and goes back to being menu-bar only when the last closes.
enum DockPresence {
    private static var open: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func show(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if open[id] == nil {
            open[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { closed(id) }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func closed(_ id: ObjectIdentifier) {
        open.removeValue(forKey: id).map(NotificationCenter.default.removeObserver)
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

@Observable final class SettingsModel {
    var settings = Settings.default
    var error: String?
    var registrations: [String: Hotkeys.Registration] = [:]
    var checks: [SetupCheck] = []
    var profiles: [Profile] = []
    var profileProblems: [ProfileStore.Problem] = []
    /// Open windows' apps and titles, for title rules' match counts.
    var windowTitles: [(app: String, title: String)] = []
    /// What the menu-bar item shows now, for the Menu Bar pane's preview.
    var status = WindowManager.Status()
    /// Why the last profile change failed, until one succeeds.
    var actionError: String?
    /// What the next key press will be recorded as, if anything.
    var recording: RecordTarget?

    enum RecordTarget: Equatable {
        /// Re-record an existing chord, keeping its command.
        case chord(String)
        /// Add a new chord for a command.
        case add(String)
        /// A new shared prefix for these commands: hold the modifiers, then release.
        case prefix([String])
    }

    /// The most modifiers held so far while recording a prefix.
    private var prefixPeak: Set<KeyChord.Modifier> = []
    var tab = "General"
    /// Opens the Welcome window, from Permissions & macOS.
    var showWelcome: () -> Void = {}
    var showProfiles: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    /// Lets the window update what SwiftUI doesn't draw, like the checks pane's toolbar label.
    var didRefresh: () -> Void = {}

    /// Desktop `number`'s label and layout, or empty ones for a Desktop with no entry yet.
    func spaceSettings(_ number: Int) -> SpacetileCore.Settings.SpaceSettings {
        settings.spaces.first { $0.space == number } ?? .init(space: number, label: nil, layout: nil)
    }

    /// Changes Desktop `number`'s settings, adding its entry the first time: config.json starts with
    /// ten, and Desktops beyond those get one when first labelled or given a layout.
    func changeSpace(_ number: Int, _ change: (inout SpacetileCore.Settings.SpaceSettings) -> Void) {
        if let index = settings.spaces.firstIndex(where: { $0.space == number }) {
            change(&settings.spaces[index])
        } else {
            var entry = spaceSettings(number)
            change(&entry)
            settings.spaces.append(entry)
            settings.spaces.sort { $0.space < $1.space }
        }
    }

    /// The keys for these commands, for sentences that mention them.
    func keyHint(_ commands: String...) -> String { settings.shortcutText(commands) ?? "(no shortcut)" }

    /// Checks that need fixing, for the tab's title.
    var problemCount: Int { checks.filter { $0.state == .warning }.count }
    /// How many Spaces exist: settings only show these, keeping the rest stored.
    var spaceCount = 1
    /// Development aid (`spacetile-ctl spaces-override N`): pretend there are N Spaces.
    static var spaceCountOverride: Int?

    private let config: ConfigStore
    private let hotkeys: Hotkeys
    private let manager: WindowManager
    /// Which live window each profile reference matches, for previews in the profile editor.
    private(set) var liveWindows: [SpacetileCore.WindowRef: WindowID] = [:]

    /// Matches profile references to live windows again and captures their pictures.
    func refreshPreviews() {
        guard settings.showsWindowPreviews else { return }
        liveWindows = manager.liveWindows()
        WindowPreviews.shared.refresh(Array(liveWindows.values))
    }

    private var keyMonitor: Any?

    init(config: ConfigStore, hotkeys: Hotkeys, manager: WindowManager) {
        self.config = config
        self.hotkeys = hotkeys
        self.manager = manager
    }

    func refresh() {
        settings = config.settings
        error = config.error
        registrations = Dictionary(hotkeys.registrations.map { ($0.chord, $0) }, uniquingKeysWith: { a, _ in a })
        spaceCount = Self.spaceCountOverride ?? Spaces.mostDesktops
        checks = SetupCheck.all(spaceCount: spaceCount)
        (profiles, profileProblems) = ProfileStore.load()
        // Keeps the menu-bar item's profile icon and name in step with edits
        manager.profilesChanged(profiles)
        windowTitles = manager.windowTitles()
        status = manager.status
        didRefresh()
    }

    enum Pane { case general, keys, rules, spaces, menuBar }

    /// Moves a config.json that doesn't parse to the Trash, then writes the settings still running.
    func revertConfig() {
        try? FileManager.default.trashItem(at: ConfigStore.file, resultingItemURL: nil)
        config.save(config.settings)
        refresh()
    }

    /// Puts one pane's settings back to the defaults, undoably.
    func restoreDefaults(_ pane: Pane) {
        let defaults = SpacetileCore.Settings.default
        switch pane {
        case .general:
            settings.focusFollowsMouse = defaults.focusFollowsMouse
            settings.mouseFollowsFocus = defaults.mouseFollowsFocus
            settings.followAfterSending = defaults.followAfterSending
            settings.followRoutedWindows = defaults.followRoutedWindows
            settings.windowPreviews = defaults.windowPreviews
            settings.nativeTiling = defaults.nativeTiling
            settings.padding = defaults.padding
            settings.gap = defaults.gap
            settings.spacing = defaults.spacing
            settings.activeBorder = defaults.activeBorder
            settings.dimInactive = defaults.dimInactive
            settings.borderColor = defaults.borderColor
            settings.borderOpacity = defaults.borderOpacity
            settings.dimOpacity = defaults.dimOpacity
            settings.animateWindows = defaults.animateWindows
            settings.ratio = defaults.ratio
            settings.tiling = defaults.tiling
            settings.stacking = defaults.stacking
        case .keys:
            settings.keys = defaults.keys
            settings.shortcuts = defaults.shortcuts
        case .rules:
            settings.floatApps = defaults.floatApps
            settings.floatTitles = defaults.floatTitles
            settings.appSpaces = defaults.appSpaces
            settings.fullScreenApps = defaults.fullScreenApps
        case .spaces: settings.spaces = defaults.spaces
        case .menuBar: settings.menuBar = nil
        }
        save("Restore Defaults")
    }

    /// Gives these commands their default shortcuts back, leaving every other binding alone.
    /// Swaps every shortcut for another tool's defaults, and says what that tool has that Spacetile
    /// can't do.
    func apply(_ preset: KeyPreset) {
        settings.keys = preset.settingsKeys
        save("Use \(preset.name) Shortcuts")
        let moved = preset.fallbacks.filter { settings.keys[$0.key] == $0.value }.sorted { $0.value < $1.value }
            .map { "\($0.value) to \(KeyChord($0.key)?.symbols ?? $0.key)" }
        notice = "Using \(preset.name)'s shortcuts."
            + (preset.unmatched.isEmpty ? "" : " Not in Spacetile: " + preset.unmatched.joined(separator: ", ") + ".")
            + (moved.isEmpty ? "" : " Moved to make room: " + moved.joined(separator: ", ") + ".")
            + (preset.displaced.isEmpty ? "" : " Now without a shortcut: " + preset.displaced.joined(separator: ", ") + ".")
    }

    func restoreDefaultKeys(for commands: [String]) {
        let commands = Set(commands)
        settings.keys = settings.keys.filter { !commands.contains($0.value) }
        for (chord, command) in SpacetileCore.Settings.default.keys where commands.contains(command) { settings.keys[chord] = command }
        save("Restore Default Shortcuts")
    }

    /// Undo for Settings and Profiles: Edit › Undo names the change, e.g. "Undo Remove Float Rule".
    let undo = UndoManager()

    /// Writes the edited settings, recording the ones they replace so Edit › Undo can put them back.
    func save(_ action: String = "Change Setting") {
        let before = config.settings
        guard before != settings else { return refresh() }
        config.save(settings)
        undoable(action) { model in
            model.settings = before
            model.save(action)
        }
        refresh()
    }

    /// Registers `undo`, which itself registers the redo when it runs.
    private func undoable(_ action: String, _ undo: @escaping @MainActor (SettingsModel) -> Void) {
        self.undo.registerUndo(withTarget: self) { model in MainActor.assumeIsolated { undo(model) } }
        self.undo.setActionName(action)
    }

    // MARK: Key recording

    /// Records the next key press for `target`. Global hotkeys are released while recording,
    /// otherwise pressing an existing binding would run it instead of being recorded. Key codes are
    /// recorded rather than characters, since ⌥ turns letters into accents. Esc cancels.
    func record(_ target: RecordTarget) {
        stopRecording()
        notice = nil
        recording = target
        prefixPeak = []
        hotkeys.suspend()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.recorded(event) }
            return nil
        }
    }

    private func recorded(_ event: NSEvent) {
        guard let target = recording else { return }
        let flags = event.modifierFlags
        let modifiers = Set<KeyChord.Modifier>([
            flags.contains(.control) ? .ctrl : nil, flags.contains(.option) ? .alt : nil,
            flags.contains(.shift) ? .shift : nil, flags.contains(.command) ? .cmd : nil,
        ].compactMap { $0 })
        // A prefix is the most modifiers held at once, taken when they're all released
        if case .prefix(let commands) = target, event.type == .flagsChanged {
            prefixPeak.formUnion(modifiers)
            guard modifiers.isEmpty, !prefixPeak.isEmpty else { return }
            let prefix = prefixPeak
            stopRecording()
            return setModifiers(prefix, for: commands)
        }
        guard event.type == .keyDown else { return }
        defer { stopRecording() }
        if event.keyCode == 53, modifiers.isEmpty { return } // bare Escape cancels
        guard let chord = KeyChord(keyCode: UInt32(event.keyCode), modifiers: modifiers), !modifiers.isEmpty else { return }
        if let reason = chord.reservedReason {
            notice = "\(chord.symbols) stays with macOS: \(reason) Choose another shortcut."
            return
        }
        let before = settings.keys
        switch target {
        case .prefix(let commands): return setModifiers(modifiers, for: commands)
        case .chord(let old): rename(old, to: chord.text)
        case .add(let command):
            // A chord belongs to one command; recording it here takes it from any other
            settings.keys[chord.text] = command
            save("Record Shortcut")
        }
        noteTaken(chord.text, from: before)
    }

    /// What the last recording did that's easy to miss, like taking a shortcut from another action.
    var notice: String?

    /// Says which action a recorded chord was taken from, and whether that action has any key left.
    private func noteTaken(_ chord: String, from before: [String: String]) {
        guard let previous = before[chord], previous != settings.keys[chord] else { return }
        let display = KeyChord(chord)?.symbols ?? chord
        let remaining = chords(for: previous).compactMap { KeyChord($0)?.symbols }
        notice = "\(display) was “\(KeyAction.title(for: previous))”, which "
            + (remaining.isEmpty ? "now has no shortcut." : "keeps \(remaining.joined(separator: ", ")).")
    }

    func stopRecording() {
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
        if recording != nil { hotkeys.resume() }
        recording = nil
    }

    func rename(_ chord: String, to new: String) {
        guard chord != new, let command = settings.keys.removeValue(forKey: chord) else { return }
        settings.keys[new] = command
        save("Record Shortcut")
    }

    func remove(_ chord: String) {
        settings.keys[chord] = nil
        save("Remove Shortcut")
    }

    /// Chords bound to a command, in a stable order.
    func chords(for command: String) -> [String] {
        settings.keys.filter { $0.value == command }.map(\.key).sorted()
    }

    /// The modifiers a group of commands shares, e.g. "alt" for `space 1`…`space 10`, or nil if
    /// they disagree or aren't bound.
    func sharedModifiers(of commands: [String]) -> Set<KeyChord.Modifier>? {
        let sets = Set(commands.flatMap { chords(for: $0) }.compactMap { KeyChord($0)?.modifiers })
        return sets.count == 1 ? sets.first : nil
    }

    /// Rebinds every chord of these commands from their shared modifiers to `modifiers`, keeping keys.
    func setModifiers(_ modifiers: Set<KeyChord.Modifier>, for commands: [String]) {
        let moved = commands.flatMap { chords(for: $0) }.compactMap(KeyChord.init).map { KeyChord(key: $0.key, modifiers: modifiers) }
        if let reserved = moved.first(where: { $0.reservedReason != nil }), let reason = reserved.reservedReason {
            notice = "\(reserved.symbols) stays with macOS: \(reason) Choose other modifiers."
            return
        }
        let before = settings.keys
        defer { for chord in moved { noteTaken(chord.text, from: before) } }
        for command in commands {
            for chord in chords(for: command) {
                guard let parsed = KeyChord(chord) else { continue }
                settings.keys[chord] = nil
                settings.keys[KeyChord(key: parsed.key, modifiers: modifiers).text] = command
            }
        }
        save("Change Prefix")
    }

    /// Commands whose chords differ from the defaults.
    func changedCount(_ commands: [String]) -> Int {
        let defaults = SpacetileCore.Settings.default.keys
        return commands.filter { command in Set(chords(for: command)) != Set(defaults.filter { $0.value == command }.map(\.key)) }.count
    }

    // MARK: Profiles

    func load(_ profile: Profile) { manager.perform(.load(profile.name)) }

    func capture() {
        manager.perform(.capture((NSScreen.main?.localizedName ?? "profile").lowercased()))
        refresh()
    }

    /// Saves a profile, numbering each app's windows in reading order first.
    func update(_ profile: Profile, action: String = "Change Profile") {
        let before = profiles.first { $0.name == profile.name }
        guard attempt("save “\(profile.name)”", { try ProfileStore.save(profile.renumbered()) }) else { return refresh() }
        undoable(action) { model in
            if let before { model.update(before, action: action) } else { model.trash(profile) }
        }
        refresh()
    }

    /// Runs a file change, reporting a failure in the window instead of dropping it.
    @discardableResult private func attempt(_ action: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            actionError = nil
            return true
        } catch {
            actionError = "Couldn't \(action): \(error.localizedDescription)"
            log.error("\(self.actionError ?? "", privacy: .public)")
            return false
        }
    }

    /// The profile selected in the designer.
    var selectedProfile: String?

    private func uniqueName(_ base: String) -> String {
        uniqueProfileName(base, taken: Set(profiles.map(\.name)))
    }

    func newProfile() {
        // Records the displays connected now, so each display's Desktops can be arranged
        let desktops = Spaces.desktops
        let displays = desktops.displays.map { ProfileDisplay(identity: $0.identity, frame: $0.frame, desktops: $0.spaces.count) }
        let profile = Profile(name: uniqueName("Untitled"), display: desktops.fingerprint, displays: displays,
                              spansDisplays: desktops.spansDisplays ? true : nil,
                              spaces: [SpaceSnapshot(space: 1, mode: .bsp, tree: .tile([]), floating: [], others: [],
                                                     display: desktops.main?.identity.signature)])
        update(profile)
        selectedProfile = profile.name
    }

    func duplicate(_ profile: Profile) {
        var copy = profile
        copy.name = uniqueName(profile.name + " copy")
        copy.display = nil
        update(copy)
        selectedProfile = copy.name
    }

    /// Renames the file and any `load <name>` shortcut with it.
    func rename(_ profile: Profile, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard name != profile.name, profileNameProblem(name, current: profile.name, taken: Set(profiles.map(\.name))) == nil else { return }
        var renamed = profile
        renamed.name = name
        // A rename that only changes case keeps the same file on a case-insensitive disk
        let oldFile = ProfileStore.file(of: profile)
        let sameFile = { (try? oldFile.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier).map { $0 as AnyObject }
            .flatMap { old in (try? ProfileStore.file(of: renamed).resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier).map { old.isEqual($0) } } == true }
        let before = sameFile()
        guard attempt("rename “\(profile.name)”", { try ProfileStore.save(renamed.renumbered()) }) else { return }
        if !before { trashFile(of: profile) }
        manager.profilesChanged(ProfileStore.all, renamed: (profile.name, name))
        for chord in chords(for: "load \(profile.name)") { settings.keys[chord] = "load \(name)" }
        selectedProfile = name
        undo.disableUndoRegistration()
        save()
        undo.enableUndoRegistration()
        undoable("Rename Profile") { model in
            model.profiles.first { $0.name == name }.map { model.rename($0, to: profile.name) }
        }
    }

    func captureNew() {
        let name = uniqueName((NSScreen.main?.localizedName ?? "profile").lowercased())
        manager.perform(.capture(name))
        refresh()
        selectedProfile = name
    }

    func recapture(_ profile: Profile) {
        manager.recapture(profile)
        refresh()
    }

    func trash(_ profile: Profile) {
        let wasCurrent = manager.lastProfile == profile.name
        trashFile(of: profile)
        if selectedProfile == profile.name { selectedProfile = nil }
        undoable("Move to Trash") { model in
            model.update(profile, action: "Move to Trash")
            if wasCurrent { model.manager.makeCurrent(profile) }
            model.selectedProfile = profile.name
        }
        refresh()
    }

    private func trashFile(of profile: Profile) {
        attempt("move “\(profile.name)” to the Trash") { try FileManager.default.trashItem(at: ProfileStore.file(of: profile), resultingItemURL: nil) }
    }

    var runningApps: [String] {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)).sorted()
    }

    /// Whether an app by this name is running or installed, the names rules can match.
    func knowsApp(_ name: String) -> Bool {
        InstalledApps.paths[name] != nil || runningApps.contains(name)
            // System utilities like Archive Utility live outside the Applications folders
            || ["/System/Library/CoreServices", "/System/Library/CoreServices/Applications"]
                .contains { FileManager.default.fileExists(atPath: "\($0)/\(name).app") }
    }

    /// Every installed app by display name, the name rules match on.
    var installedApps: [String] { InstalledApps.names }
}

/// Apps in the usual Applications folders (one level of subfolders deep, for suites like
/// Microsoft Office), scanned once per launch.
enum InstalledApps {
    static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                          "/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    /// Display name → bundle path.
    static let paths: [String: String] = {
        let files = FileManager.default
        func apps(in folder: String, depth: Int) -> [(String, String)] {
            let entries = (try? files.contentsOfDirectory(atPath: folder)) ?? []
            return entries.flatMap { entry -> [(String, String)] in
                let path = folder + "/" + entry
                if entry.hasSuffix(".app") {
                    // The bundle's display name is what the app shows in the menu bar
                    let bundle = Bundle(path: path)
                    let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? String(entry.dropLast(4))
                    return [(name, path)]
                }
                var isFolder: ObjCBool = false
                guard depth > 0, files.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return [] }
                return apps(in: path, depth: depth - 1)
            }
        }
        return Dictionary(folders.flatMap { apps(in: $0, depth: 1) }, uniquingKeysWith: { first, _ in first })
    }()

    static let names: [String] = paths.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    /// Display name → bundle ID, for profiles, which name apps by bundle ID.
    static let bundleIDs: [String: String] = paths.compactMapValues { Bundle(path: $0)?.bundleIdentifier }

    /// The display name for a bundle ID, from a running or installed app.
    static func name(forBundleID id: String) -> String {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.localizedName
            ?? bundleIDs.first { $0.value == id }?.key
            ?? id
    }

    /// A bundle ID for a display name, from a running or installed app.
    static func bundleID(forName name: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleIdentifier ?? bundleIDs[name]
    }
}

/// One macOS setting Spacetile relies on, read from its preferences domain.
struct SetupCheck: Identifiable {
    let id: String
    let state: State
    let detail: String
    let pane: String

    enum State { case ok, warning, suggestion }

    init(id: String, ok: Bool, detail: String, pane: String) {
        self.init(id: id, state: ok ? .ok : .warning, detail: detail, pane: pane)
    }

    init(id: String, state: State, detail: String, pane: String) {
        self.id = id
        self.state = state
        self.detail = detail
        self.pane = pane
    }

    /// Spacetile tiles within native Spaces but can't create them, so a single Space gets a nudge
    /// rather than a warning: everything works, there's just nowhere to switch or send windows.
    static func spacesCheck(count: Int) -> SetupCheck {
        let pane = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        guard count > 1 else {
            return SetupCheck(id: "Add a few Spaces", state: .suggestion,
                              detail: "You have one Space. Spacetile tiles within macOS Spaces but can't create them. Add some in Mission Control (⌃↑, then +) to switch and send windows between them; Settings will show the new ones.",
                              pane: pane)
        }
        return SetupCheck(id: "\(count) Spaces", ok: true,
                          detail: "Settings show Spaces 1–\(count). Add or remove Spaces in Mission Control whenever you like.", pane: pane)
    }

    static let accessibilityID = "Accessibility permission"
    static let accessibilityPane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"

    static func all(spaceCount: Int) -> [SetupCheck] {
        func value(_ key: String, _ domain: String) -> Int? {
            CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int
        }
        let missionControl = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        let swipe = [value("TrackpadThreeFingerHorizSwipeGesture", "com.apple.AppleMultitouchTrackpad"),
                     value("TrackpadFourFingerHorizSwipeGesture", "com.apple.AppleMultitouchTrackpad")].contains(2)
        return [
            SetupCheck(id: accessibilityID, ok: AXIsProcessTrusted(),
                       detail: "Needed to see, move and resize other apps' windows.", pane: accessibilityPane),
            SetupCheck(id: "Automatically rearrange Spaces: off", ok: value("mru-spaces", "com.apple.dock") == 0,
                       detail: "Otherwise Space numbers shuffle and switching by number lands on the wrong Space.", pane: missionControl),
            spacesCheck(count: spaceCount),
            SetupCheck(id: "Stage Manager: off", ok: value("GloballyEnabled", "com.apple.WindowManager") != 1,
                       detail: "Stage Manager moves windows itself and fights tiling.", pane: missionControl),
            SetupCheck(id: "Drag windows to edges to tile: off", ok: value("EnableTilingByEdgeDrag", "com.apple.WindowManager") == 0,
                       detail: "macOS's edge-drag preview competes with Spacetile's drop zones. The green button's tiling, the Window menu and fn⌃ arrows work with Spacetile either way.",
                       pane: missionControl),
            SetupCheck(id: "Trackpad swipe between Spaces: on", ok: swipe,
                       detail: "macOS 27 only accepts Spacetile's instant switching when this gesture is enabled.",
                       pane: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"),
        ]
    }
}

// MARK: - Views

/// An error with the actions that fix it, above the pane.
struct ErrorBanner<Actions: View>: View {
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .multilineTextAlignment(.leading)
            Spacer()
            actions()
        }
        .padding(10)
        .background(.background.secondary)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The bottom bar of a pane, with its Restore Defaults button. Undo takes a restore back.
struct RestoreDefaultsBar: View {
    let restore: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Restore Defaults", action: restore)
                .help("Puts this pane back to how Spacetile ships. Edit › Undo takes it back.")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A pane with the config and file errors above it, so they show whichever pane is open.
struct PaneView<Content: View>: View {
    var model: SettingsModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                ErrorBanner(message: error) {
                    Button("Open config.json") { NSWorkspace.shared.open(ConfigStore.file) }
                    Button("Revert to Last Good") { model.revertConfig() }
                        .help("Moves the broken config.json to the Trash and writes the settings Spacetile is running with")
                }
            }
            if let error = model.actionError {
                ErrorBanner(message: error) { EmptyView() }
            }
            content()
        }
    }
}

struct SetupTab: View {
    var model: SettingsModel

    static func symbol(_ state: SetupCheck.State) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .suggestion: "info.circle.fill"
        }
    }

    static func color(_ state: SetupCheck.State) -> Color {
        switch state {
        case .ok: .green
        case .warning: .orange
        case .suggestion: .blue
        }
    }

    var body: some View {
        Form {
            ForEach(model.checks) { SetupCheckRow(check: $0) }
            HStack {
                Button("Check Again") { model.refresh() }
                Spacer()
                Button("Show Welcome Guide") { model.showWelcome() }
            }
        }
        .formStyle(.grouped)
    }
}

/// One check: its state, what it's for, and a link to the System Settings pane that fixes it.
struct SetupCheckRow: View {
    let check: SetupCheck

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: SetupTab.symbol(check.state)).foregroundStyle(SetupTab.color(check.state))
                .accessibilityLabel(check.state == .ok ? "Done" : check.state == .warning ? "Needs attention" : "Suggestion")
            VStack(alignment: .leading) {
                Text(check.id)
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if check.state != .ok, let url = URL(string: check.pane) {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

struct RulesTab: View {
    @Bindable var model: SettingsModel
    @State private var newFloat = ""
    @State private var newApp = ""
    @State private var newSpace = 1
    @State private var newFullScreen = ""
    @State private var newTitleApp = ""
    @State private var newTitle = ""

    /// Why `name` can't be added to a list that has `existing`, or a warning that it matches no app.
    private func nameNote(_ name: String, in existing: some Collection<String>) -> (text: String, blocks: Bool)? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if existing.contains(name) { return ("“\(name)” is already in this list.", true) }
        if !model.knowsApp(name) { return ("No running or installed app is called “\(name)”. Rules match the name in the app's menu bar.", false) }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Text("Rules decide how Spacetile treats an app's windows, matched by the app's name as shown in the menu bar. Changes apply to windows that open from now on; use \(model.keyHint("float")) to float or tile an open window.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.settings.floatApps, id: \.self) { app in
                    HStack {
                        AppLabel(name: app)
                        UnknownAppMark(known: model.knowsApp(app), name: app)
                        Spacer()
                        removeButton("Remove Float Rule") { model.settings.floatApps.removeAll { $0 == app } }
                    }
                }
                let floatNote = nameNote(newFloat, in: model.settings.floatApps)
                HStack {
                    AppField(name: $newFloat, running: model.runningApps, installed: model.installedApps)
                    Button("Add") {
                        model.settings.floatApps = (model.settings.floatApps + [newFloat.trimmingCharacters(in: .whitespaces)]).sorted()
                        newFloat = ""
                        model.save("Add Float Rule")
                    }.disabled(newFloat.trimmingCharacters(in: .whitespaces).isEmpty || floatNote?.blocks == true)
                }
                if let floatNote { FieldNote(text: floatNote.text, blocking: floatNote.blocks) }
            } header: {
                Text("Always float")
            } footer: {
                Text("These apps' windows are never tiled: they keep their own size and position and stay on top of tiled windows when you hover. Good for utilities, calculators and settings windows.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                ForEach(Array(model.settings.floatTitles.enumerated()), id: \.offset) { index, rule in
                    HStack {
                        AppLabel(name: rule.app)
                        UnknownAppMark(known: model.knowsApp(rule.app), name: rule.app)
                        Text(rule.title).font(.body.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.matchText(rule.matches(in: model.windowTitles))).font(.caption).foregroundStyle(.secondary)
                        removeButton("Remove Title Rule") { model.settings.floatTitles.remove(at: index) }
                    }
                }
                let titleProblem = newTitle.isEmpty ? nil : SpacetileCore.Settings.TitleRule.problem(with: newTitle)
                let titleNote = nameNote(newTitleApp, in: [String]())
                HStack {
                    AppField(name: $newTitleApp, running: model.runningApps, installed: model.installedApps)
                    TextField("Title", text: $newTitle, prompt: Text("Title contains, e.g. Info|Copy"))
                        .labelsHidden().textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Button("Add") {
                        model.settings.floatTitles.append(.init(app: newTitleApp.trimmingCharacters(in: .whitespaces), title: newTitle))
                        newTitleApp = ""
                        newTitle = ""
                        model.save("Add Title Rule")
                    }.disabled(newTitleApp.trimmingCharacters(in: .whitespaces).isEmpty || newTitle.isEmpty || titleProblem != nil)
                }
                if let titleProblem {
                    FieldNote(text: titleProblem, blocking: true)
                } else if !newTitle.isEmpty, !newTitleApp.isEmpty {
                    let rule = SpacetileCore.Settings.TitleRule(app: newTitleApp.trimmingCharacters(in: .whitespaces), title: newTitle)
                    FieldNote(text: "This rule \(Self.matchText(rule.matches(in: model.windowTitles))).", blocking: false, info: true)
                }
                if let titleNote { FieldNote(text: titleNote.text, blocking: false) }
            } header: {
                Text("Float windows whose title matches")
            } footer: {
                Text("For apps where only some windows should float, like Finder's copy and info windows. The title is a regular expression and floats the window if it matches anywhere in the title.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                ForEach(model.settings.appSpaces.filter { $0.value <= model.spaceCount }.keys.sorted(), id: \.self) { app in
                    HStack {
                        AppLabel(name: app)
                        UnknownAppMark(known: model.knowsApp(app), name: app)
                        Spacer()
                        Picker("", selection: Binding(get: { model.settings.appSpaces[app] ?? 1 },
                                                      set: { model.settings.appSpaces[app] = $0; model.save() })) {
                            ForEach(1...model.spaceCount, id: \.self) { Text("Desktop \($0)").tag($0) }
                        }
                        .labelsHidden().frame(width: 120)
                        removeButton("Remove Space Rule") { model.settings.appSpaces[app] = nil }
                    }
                }
                let spaceNote = nameNote(newApp, in: model.settings.appSpaces.keys)
                HStack {
                    AppField(name: $newApp, running: model.runningApps, installed: model.installedApps)
                    Picker("", selection: $newSpace) { ForEach(1...model.spaceCount, id: \.self) { Text("Desktop \($0)").tag($0) } }
                        .labelsHidden().frame(width: 120)
                    Button("Add") {
                        model.settings.appSpaces[newApp.trimmingCharacters(in: .whitespaces)] = newSpace
                        newApp = ""
                        model.save("Add Space Rule")
                    }.disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty || spaceNote?.blocks == true)
                }
                if let spaceNote { FieldNote(text: spaceNote.text, blocking: spaceNote.blocks) }
            } header: {
                Text("Send new windows to a Space")
            } footer: {
                Text("When one of these apps opens a new window, Spacetile moves it to its Space. Windows that are already open stay where they are; use a profile to rearrange those. Whether you follow the window is set in General → Follow when routed by a rule."
                     + Self.hiddenNote(model.settings.appSpaces.values.filter { $0 > model.spaceCount }.count, model.spaceCount))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                ForEach((model.settings.fullScreenApps ?? []).sorted(), id: \.self) { app in
                    HStack {
                        AppLabel(name: app)
                        UnknownAppMark(known: model.knowsApp(app), name: app)
                        Spacer()
                        removeButton("Remove Full Screen Rule") { model.settings.fullScreenApps?.removeAll { $0 == app } }
                    }
                }
                let fullScreenNote = nameNote(newFullScreen, in: model.settings.fullScreenApps ?? [])
                HStack {
                    AppField(name: $newFullScreen, running: model.runningApps, installed: model.installedApps)
                    Button("Add") {
                        model.settings.fullScreenApps = ((model.settings.fullScreenApps ?? []) + [newFullScreen.trimmingCharacters(in: .whitespaces)]).sorted()
                        newFullScreen = ""
                        model.save("Add Full Screen Rule")
                    }.disabled(newFullScreen.trimmingCharacters(in: .whitespaces).isEmpty || fullScreenNote?.blocks == true)
                }
                if let fullScreenNote { FieldNote(text: fullScreenNote.text, blocking: fullScreenNote.blocks) }
            } header: {
                Text("Open full screen")
            } footer: {
                Text("New windows of these apps go native full screen, after any Space rule above has moved them, so the full-screen Space sits after that Desktop. Leaving full screen puts the window back in its tile.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { RestoreDefaultsBar { model.restoreDefaults(.rules) } }
    }

    static func matchText(_ count: Int) -> String {
        "matches \(count == 0 ? "no" : String(count)) open window\(count == 1 ? "" : "s")"
    }

    /// Mentions rules kept for Spaces that don't exist yet, so they don't seem to have vanished.
    static func hiddenNote(_ hidden: Int, _ spaces: Int) -> String {
        hidden == 0 ? "" : "\n\(hidden) rule\(hidden == 1 ? "" : "s") for Spaces beyond \(spaces) \(hidden == 1 ? "is" : "are") kept but hidden until you create those Spaces."
    }

    private func removeButton(_ action: String, _ remove: @escaping () -> Void) -> some View {
        Button(role: .destructive) {
            remove()
            model.save(action)
        } label: { Label("Remove", systemImage: "minus.circle").labelStyle(.iconOnly) }
        .buttonStyle(.borderless).help("Remove")
    }
}

/// A line under a field: why it can't be added (red), a warning (orange) or information.
struct FieldNote: View {
    let text: String
    let blocking: Bool
    var info = false

    var body: some View {
        Label(text, systemImage: info ? "info.circle" : blocking ? "xmark.circle" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(info ? AnyShapeStyle(.secondary) : blocking ? AnyShapeStyle(.red) : AnyShapeStyle(.orange))
    }
}

/// A rule for an app that isn't installed or running still works once it is; this says so.
struct UnknownAppMark: View {
    let known: Bool
    let name: String

    var body: some View {
        if !known {
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                .help("No running or installed app is called “\(name)”. The rule applies once one is; rules match the name in the app's menu bar.")
                .accessibilityLabel("Unknown app")
        }
    }
}

/// A text field for an app name with a menu of running apps to pick from.
struct AppField: View {
    @Binding var name: String
    let running: [String]
    let installed: [String]

    var body: some View {
        HStack(spacing: 4) {
            // In a Form a titled field shows its title as a row label; hide it and use a prompt
            TextField("App name", text: $name, prompt: Text("App name"))
                .labelsHidden().textFieldStyle(.roundedBorder)
            Menu {
                Section("Running") { items(running) }
                Section("All applications") { items(installed.filter { !running.contains($0) }) }
            } label: { Label("Choose an app", systemImage: "chevron.down").labelStyle(.iconOnly) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Choose an app")
        }
    }

    private func items(_ apps: [String]) -> some View {
        ForEach(apps, id: \.self) { app in
            Button { name = app } label: { Label { Text(app) } icon: { Image(nsImage: AppIcons.icon(for: app)) } }
        }
    }
}

struct SpacesTab: View {
    @Bindable var model: SettingsModel
    /// The Space whose label is being edited: leaving the field saves it, like Return does.
    @FocusState private var editing: Int?

    var body: some View {
        Form {
            Text("Desktops are numbered as Mission Control labels them, without full-screen apps, so each keeps its label and layout when a full-screen app opens before it. Layouts apply to Desktops laid out after the change: switch to one and use \(model.keyHint("layout stack")) (stack) or \(model.keyHint("layout bsp")) (tile) to change it now."
                 + (model.spaceCount < model.settings.spaces.count
                    ? " Showing your \(model.spaceCount) Desktop\(model.spaceCount == 1 ? "" : "s"); settings for the others are kept for when you add them in Mission Control."
                    : ""))
                .font(.caption).foregroundStyle(.secondary)
            // A row for every Desktop that exists, whether or not config.json has an entry for it yet
            ForEach(1...max(model.spaceCount, 1), id: \.self) { number in
                HStack {
                    Text("Desktop \(number)").frame(width: 80, alignment: .leading)
                    TextField("Label", text: Binding(get: { model.spaceSettings(number).label ?? "" },
                                                     set: { label in model.changeSpace(number) { $0.label = label.isEmpty ? nil : label } }),
                              prompt: Text("No label"))
                        .labelsHidden()
                        .focused($editing, equals: number)
                        .onSubmit { model.save("Change Space Label") }
                    LayoutModePicker(mode: Binding(get: { model.spaceSettings(number).layout ?? .bsp },
                                                   set: { mode in
                                                       model.changeSpace(number) { $0.layout = mode == .bsp ? nil : mode }
                                                       model.save("Change Layout")
                                                   }))
                }
            }
            Section("Profiles") {
                LabeledContent {
                    Button("Edit Profiles…") { model.showProfiles() }
                } label: {
                    Text("Saved arrangements")
                    Text("Capture how your Spaces look, then apply it again in one go: which apps go on which Desktop and how they're tiled.")
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { RestoreDefaultsBar { model.restoreDefaults(.spaces) } }
        .onChange(of: editing) { left, _ in if left != nil { model.save("Change Space Label") } }
    }
}

struct MenuBarTab: View {
    @Bindable var model: SettingsModel

    private var menuBar: MenuBarSettings { model.settings.menuBarSettings }

    private func update(_ change: (inout MenuBarSettings) -> Void) {
        var updated = menuBar
        updated.items = updated.orderedItems
        change(&updated)
        model.settings.menuBar = updated
        model.save()
    }

    var body: some View {
        Form {
            Section {
                // Drawn by the same renderer as the real item, from the settings as they are now
                HStack {
                    Spacer()
                    if let image = MenuBarRenderer.image(for: model.status, settings: menuBar, warning: false) {
                        Image(nsImage: image).renderingMode(.template).foregroundStyle(.primary)
                            .accessibilityLabel("Menu-bar item preview")
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            } header: {
                Text("Preview")
            } footer: {
                Text("How the item looks on the current Space.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar contents (drag to reorder)") {
                List {
                    ForEach(menuBar.orderedItems, id: \.item) { entry in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Image(systemName: Self.icon(entry.item)).frame(width: 22)
                            VStack(alignment: .leading) {
                                Text(Self.title(entry.item))
                                Text(Self.detail(entry.item)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { entry.shown }, set: { shown in
                                update { $0.items = $0.items.map { $0.item == entry.item ? .init($0.item, shown: shown) : $0 } }
                            }))
                            .labelsHidden().toggleStyle(.switch)
                        }
                    }
                    .onMove { from, to in update { $0.items.move(fromOffsets: from, toOffset: to) } }
                }
                .frame(minHeight: 316)
            }
            Section("Space index style") {
                Picker("", selection: Binding(get: { menuBar.indexStyle }, set: { style in update { $0.indexStyle = style } })) {
                    VStack(alignment: .leading) {
                        Text("Index only")
                        Text("The current Space number in a single square").font(.caption).foregroundStyle(.secondary)
                    }.tag(MenuBarSettings.IndexStyle.single)
                    VStack(alignment: .leading) {
                        Text("Index stepper")
                        Text("One square per Space: the current one filled, Spaces with windows outlined").font(.caption).foregroundStyle(.secondary)
                    }.tag(MenuBarSettings.IndexStyle.stepper)
                    VStack(alignment: .leading) {
                        Text("Every display")
                        Text("The current Space on each display, the active one bright. Every menu bar shows the same item, so this shows them all").font(.caption).foregroundStyle(.secondary)
                    }.tag(MenuBarSettings.IndexStyle.displays)
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { RestoreDefaultsBar { model.restoreDefaults(.menuBar) } }
    }

    static func title(_ item: MenuBarSettings.Item) -> String {
        switch item {
        case .logo: "Spacetile logo"
        case .index: "Space index"
        case .name: "Space name"
        case .layout: "Layout mode"
        case .windowCount: "Window count"
        case .stacked: "Stacked windows"
        case .profileIcon: "Profile icon"
        case .profileName: "Profile name"
        }
    }

    static func detail(_ item: MenuBarSettings.Item) -> String {
        switch item {
        case .logo: "The Spacetile mark"
        case .index: "Your position in the Space list, in the style below"
        case .name: "The current Space's label, from the Spaces tab"
        case .layout: "BSP, Stack or Float for the current Space"
        case .windowCount: "Windows Spacetile manages on the current Space"
        case .stacked: "Windows stacked out of sight on the current Space, e.g. +2"
        case .profileIcon: "The icon of the profile applied last, chosen in the profile editor"
        case .profileName: "The name of the profile applied last"
        }
    }

    static func icon(_ item: MenuBarSettings.Item) -> String {
        switch item {
        case .logo: "square.grid.2x2"
        case .index: "square.grid.3x1.below.line.grid.1x2"
        case .name: "tag"
        case .layout: LayoutMode.bsp.symbol
        case .windowCount: "macwindow"
        case .stacked: "square.stack"
        case .profileIcon: Profile.defaultIcon
        case .profileName: "character.cursor.ibeam"
        }
    }
}

struct GeneralTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Startup") {
                LoginItemToggle()
            }
            Section("Updates") {
                UpdatesSection(check: model.checkForUpdates)
            }
            Section("Mouse") {
                toggle("Focus follows mouse",
                       "Moving the pointer onto a window focuses it, without raising it above floating windows.",
                       \.focusFollowsMouse)
                toggle("Mouse follows focus",
                       "Focusing a window with the keyboard moves the pointer to its centre, unless it's already inside.",
                       \.mouseFollowsFocus)
            }
            Section {
                toggle("Show window previews",
                       "Draw each window's content in the menu-bar mini-map and the profile editor, instead of its app's icon. Pictures stay in memory and are never saved.",
                       Binding(get: { model.settings.showsWindowPreviews }, set: { on in
                           model.settings.windowPreviews = on
                           model.save()
                           // The first time, macOS asks; after that it only says whether it's on
                           if on, !WindowPreviews.permitted { _ = CGRequestScreenCaptureAccess() }
                       }))
                if model.settings.showsWindowPreviews, !WindowPreviews.permitted {
                    LabeledContent {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    } label: {
                        Label("Needs Screen Recording permission. Until it's on, windows show their app's icon.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Window previews")
            }
            Section {
                toggle("Active window border",
                       "Outline the focused window in the accent colour, or one you choose.",
                       Binding(get: { model.settings.showsActiveBorder }, set: { model.settings.activeBorder = $0; model.save() }))
                if model.settings.showsActiveBorder {
                    LabeledContent("Border colour") {
                        HStack {
                            if model.settings.borderColor != nil {
                                Button("Use Accent Colour") {
                                    // Closed first, or the open panel writes the accent colour back as a custom one
                                    if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
                                    model.settings.borderColor = nil
                                    model.save()
                                }
                            }
                            ColorPicker("Border colour", selection: Binding(
                                get: { model.settings.borderColor.flatMap(NSColor.init(hex:)).map { Color(nsColor: $0) } ?? .accentColor },
                                set: { model.settings.borderColor = NSColor($0).hex; model.save() }
                            ), supportsOpacity: false)
                            .labelsHidden()
                        }
                    }
                    OpacitySlider(title: "Border opacity", value: Binding(get: { model.settings.activeBorderOpacity }, set: { model.settings.borderOpacity = $0; model.save() }),
                                  range: Settings.borderOpacityRange)
                }
                toggle("Dim other windows",
                       "Shade everything behind the focused window on its display. Clicks still go through to the windows underneath.",
                       Binding(get: { model.settings.dimsInactive }, set: { model.settings.dimInactive = $0; model.save() }))
                if model.settings.dimsInactive {
                    OpacitySlider(title: "Dimming", value: Binding(get: { model.settings.inactiveDimOpacity }, set: { model.settings.dimOpacity = $0; model.save() }),
                                  range: Settings.dimOpacityRange)
                }
            } header: {
                Text("Focused window")
            } footer: {
                Text("Spacetile draws both round the window, so they work with SIP on. To switch them from the keyboard, give them shortcuts in Keys → Spacetile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                toggle("Animate windows",
                       "Slide and resize windows into their tiles instead of jumping there. Moving windows through Accessibility takes time, so tiling can feel slower with this on.",
                       Binding(get: { model.settings.animatesWindows }, set: { model.settings.animateWindows = $0; model.save() }))
            } header: {
                Text("Animation")
            } footer: {
                Text("Windows jump straight to their tiles while Reduce Motion is on in System Settings → Accessibility → Display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("macOS tiling") {
                toggle("Use macOS tiling with Spacetile",
                       "Tiling a window from its green button, the Window menu or fn⌃ arrows becomes the matching Spacetile command: halves and quarters place it, Fill zooms it, Arrange tiles the windows it arranged, and Return to Previous Size restores. The other windows re-tile round it. Off, Spacetile puts tiled windows back.",
                       Binding(get: { model.settings.adoptsNativeTiling }, set: { model.settings.nativeTiling = $0; model.save() }))
            }
            Section("Moving windows between Spaces") {
                toggle("Follow after sending",
                       "Switch to the destination Space after sending a window there with \(model.settings.shortcutText((1...10).map { "send \($0)" }) ?? "a send shortcut"), \(model.keyHint("send next", "send prev")) or fn + drag to a screen edge. Dragging in the menu-bar mini-map never follows.",
                       Binding(get: { model.settings.followsSends }, set: { model.settings.followAfterSending = $0; model.save() }))
                toggle("Follow when routed by a rule",
                       "Switch when an app rule (Rules → Send new windows to a Space) places a new window on another Space. Windows placed by a profile never pull you along.",
                       Binding(get: { model.settings.followsRouting }, set: { model.settings.followRoutedWindows = $0; model.save() }))
            }
            Section {
                Picker("Tiling", selection: Binding(get: { model.settings.tileAlgorithm }, set: { model.settings.tiling = $0 == .bsp ? nil : $0; model.save() })) {
                    ForEach(TileAlgorithm.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                Picker("Stacking", selection: Binding(get: { model.settings.stackAlgorithm }, set: { model.settings.stacking = $0 == .fill ? nil : $0; model.save() })) {
                    ForEach(StackAlgorithm.allCases, id: \.self) { Text($0.name).tag($0) }
                }
            } header: {
                Text("Layout algorithms")
            } footer: {
                Text("Tile: \(model.settings.tileAlgorithm.detail) Stack: \(model.settings.stackAlgorithm.detail) Every Space uses these.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                // Empty means automatic, so say what automatic is on the display in use
                let auto = Spacing.forDisplay(width: NSScreen.main?.frame.width ?? 1600)
                toggle("Space round windows",
                       "Off, tiles meet edge to edge and fill the display. Padding and gap are kept for when it's back on.",
                       Binding(get: { model.settings.usesSpacing }, set: { model.settings.spacing = $0; model.save() }))
                Group {
                    NumberField(title: "Padding", value: Binding(get: { model.settings.padding }, set: { model.settings.padding = $0; model.save() }),
                                range: Settings.spacingRange, placeholder: "Auto (\(Int(auto.padding)) pt on this display)")
                    NumberField(title: "Gap between windows", value: Binding(get: { model.settings.gap }, set: { model.settings.gap = $0; model.save() }),
                                range: Settings.spacingRange, placeholder: "Auto (\(Int(auto.gap)) pt on this display)")
                }
                .disabled(!model.settings.usesSpacing)
                NumberField(title: "Default split ratio", value: Binding(get: { model.settings.ratio }, set: { model.settings.ratio = $0; model.save() }),
                            range: BSPTree.ratioRange, placeholder: model.settings.tileAlgorithm == .masterStack ? "0.5: the main window's share" : "0.5: the share a window keeps when a new one splits it")
            } header: {
                Text("Spacing")
            } footer: {
                Text("Leave padding and gap empty for automatic spacing: 10 pt on wide displays, 5 pt on narrow ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CommandLineSettings()
            Section("Configuration") {
                LabeledContent("Config file") {
                    Text("~/.config/spacetile/config.json").font(.body.monospaced())
                    Button("Open") { NSWorkspace.shared.open(ConfigStore.file) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.file]) }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { RestoreDefaultsBar { model.restoreDefaults(.general) } }
    }

    private func toggle(_ title: String, _ detail: String, _ keyPath: WritableKeyPath<SpacetileCore.Settings, Bool>) -> some View {
        toggle(title, detail, Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0; model.save() }))
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail)
        }
    }
}

/// An optional number: empty means automatic. Commits on Return or when focus leaves the field. Text
/// that isn't a number in `range` is explained under the field and not saved.
/// A percentage slider that saves once, when the drag ends, so a drag is one undo step.
struct OpacitySlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var dragged: Double?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { dragged ?? value }, set: { dragged = $0 }), in: range) { editing in
                    if !editing, let dragged { value = dragged; self.dragged = nil }
                }
                Text((dragged ?? value).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    var placeholder = "Auto"
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        guard !trimmed.isEmpty else { return nil }
        guard let number = try? Double(trimmed, format: .number) else { return "Enter a number, or leave it empty for automatic." }
        return range.contains(number) ? nil : "Use a value from \(range.lowerBound.formatted()) to \(range.upperBound.formatted())."
    }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(title, text: $text, prompt: Text(placeholder))
                    .labelsHidden().multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { if !focused { commit() } }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear { text = value.map { $0.formatted() } ?? "" }
    }

    private func commit() {
        guard problem == nil else { return }
        let number = trimmed.isEmpty ? nil : try? Double(trimmed, format: .number)
        if number != value { value = number }
    }
}

/// Open at login through `SMAppService`, which registers this bundle where it lives.
struct LoginItemToggle: View {
    @State private var status = SMAppService.mainApp.status

    var body: some View {
        Toggle(isOn: Binding(get: { status == .enabled }, set: { on in
            do {
                try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            } catch {
                log.error("login item: \(error.localizedDescription, privacy: .public)")
            }
            status = SMAppService.mainApp.status
        })) {
            Text("Open at login")
            Text("Start Spacetile when you log in, so tiling and hotkeys are always on.")
        }
        if status == .requiresApproval {
            Button("Approve in System Settings") { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}

/// An app's icon and name, as rules refer to apps by name.
struct AppLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(for: name)).resizable().frame(width: 20, height: 20)
            Text(name)
        }
    }
}

/// Icons for app names: from the running app if there is one, otherwise from the usual
/// Applications folders, otherwise the generic app icon. Cached, since rows redraw often.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                  "/Applications/Utilities", NSHomeDirectory() + "/Applications",
                                  "/System/Library/CoreServices", "/System/Library/CoreServices/Applications"]

    static func icon(for name: String) -> NSImage {
        if let cached = cache[name] { return cached }
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
        let installed = (InstalledApps.paths[name] ?? folders.lazy.map { "\($0)/\(name).app" }.first { FileManager.default.fileExists(atPath: $0) })
            .map { NSWorkspace.shared.icon(forFile: $0) }
        let icon = running ?? installed ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icon.size = NSSize(width: 32, height: 32)
        cache[name] = icon
        return icon
    }
}

/// Tile, Stack or Float as icons in a segmented control; each segment names itself on hover.
struct LayoutModePicker: View {
    @Binding var mode: LayoutMode

    var body: some View {
        Picker("Layout", selection: $mode) {
            ForEach([LayoutMode.bsp, .stack, .float], id: \.self) { mode in
                Image(systemName: mode.symbol).help(Self.name(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    static func name(_ mode: LayoutMode) -> String {
        switch mode {
        case .bsp: "Tile: windows sit side by side"
        case .stack: "Stack: every window fills the Space; cycle through them with the stack keys"
        case .float: "Float: windows stay where you put them"
        }
    }
}
