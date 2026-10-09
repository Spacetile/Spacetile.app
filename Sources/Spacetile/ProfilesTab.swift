import SpacetileCore
import SwiftUI

// Carbon and SwiftUI have types with these names too
private typealias WindowRef = SpacetileCore.WindowRef
private typealias Axis = SpacetileCore.Axis

/// The profile designer: profiles in a sidebar; the selected one's options, a chip per Space, and
/// an editable picture of each Space's layout. Every change is saved to the profile's JSON file.
struct ProfilesTab: View {
    @Bindable var model: SettingsModel

    private var selected: Profile? {
        model.profiles.first { $0.name == model.selectedProfile } ?? model.profiles.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ProfileSidebar(model: model, selected: selected?.name)
                .frame(width: 210)
            Divider()
            if let profile = selected {
                ProfileDetail(model: model, profile: profile)
                    .id(profile.name)
            } else {
                ContentUnavailableView("No profiles yet", systemImage: "rectangle.3.group",
                                       description: Text("Create one, or capture how your Spaces look right now."))
            }
        }
        .onAppear { model.refreshPreviews() }
    }
}

// MARK: - Sidebar

private struct ProfileSidebar: View {
    var model: SettingsModel
    let selected: String?
    @State private var renaming: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profiles").font(.headline)
                Text("\(model.profiles.count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).background(Capsule().fill(.quaternary))
                Spacer()
            }
            .padding(10)
            List(selection: Binding(get: { selected }, set: { model.selectedProfile = $0 })) {
                ForEach(model.profiles, id: \.name) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile.symbol).font(.body).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(Self.summary(profile)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(profile.name)
                    .contextMenu {
                        Button("Apply profile") { model.load(profile) }
                        Button("Rename…") { renaming = profile }
                        Button("Duplicate") { model.duplicate(profile) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { model.trash(profile) }
                    }
                }
            }
            .listStyle(.sidebar)
            // Files that don't load: a hand-edit typo shouldn't make a profile disappear silently
            ForEach(model.profileProblems, id: \.self) { problem in
                Button { NSWorkspace.shared.open(problem.file) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(problem.file.lastPathComponent) didn't load")
                            Text(problem.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .help("Open \(problem.file.lastPathComponent) to fix it: \(problem.message)")
            }
            Divider()
            HStack(spacing: 4) {
                Menu {
                    Button("New Profile") { model.newProfile() }
                    Button("Capture Current Layout") { model.captureNew() }
                } label: { Label("New profile", systemImage: "plus").labelStyle(.iconOnly) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("New profile")
                Button { if let profile = model.profiles.first(where: { $0.name == selected }) { model.trash(profile) } } label: {
                    Label("Move to Trash", systemImage: "minus").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).disabled(selected == nil).help("Move to Trash")
                Spacer()
                Button { NSWorkspace.shared.open(ProfileStore.directory) } label: { Label("Show profile files", systemImage: "folder").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help("Show the profile files in Finder")
            }
            .padding(8)
        }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            if let renaming { RenameSheet(model: model, profile: renaming) }
        }
    }

    static func summary(_ profile: Profile) -> String {
        let windows = profile.spaces.flatMap(\.windows).count
        let fullScreen = profile.fullScreen?.count ?? 0
        return "\(profile.spaces.count) Space\(profile.spaces.count == 1 ? "" : "s") · \(windows) window\(windows == 1 ? "" : "s")"
            + (fullScreen > 0 ? " · \(fullScreen) full screen" : "")
    }
}

/// Renames a profile, saying why a name won't do rather than ignoring it.
private struct RenameSheet: View {
    var model: SettingsModel
    let profile: Profile
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(model: SettingsModel, profile: Profile) {
        self.model = model
        self.profile = profile
        _name = State(initialValue: profile.name)
    }

    private var problem: String? {
        profileNameProblem(name, current: profile.name, taken: Set(model.profiles.map(\.name)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename “\(profile.name)”").font(.headline)
            TextField("Name", text: $name).labelsHidden().onSubmit(rename)
            // Keeps its height when valid, so the buttons don't jump while typing
            Label(problem ?? " ", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.red).opacity(problem == nil ? 0 : 1)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func rename() {
        guard problem == nil else { return }
        model.rename(profile, to: name)
        dismiss()
    }
}

/// A grid of icons for a profile, in groups; the current one is highlighted.
private struct ProfileIconPicker: View {
    let selected: String
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Profile.iconChoices, id: \.title) { group in
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 6), spacing: 4) {
                    ForEach(group.icons, id: \.symbol) { symbol, name in
                        Button { choose(symbol) } label: {
                            Image(systemName: symbol).font(.system(size: 15))
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(symbol == selected ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.clear)))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(symbol == selected ? Color.accentColor : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                        .accessibilityLabel(name)
                    }
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Detail

private struct ProfileDetail: View {
    var model: SettingsModel
    let profile: Profile
    @State private var selectedSpace: Int?
    @State private var selectedDisplay: String?
    @State private var renaming = false
    @State private var choosingIcon = false

    /// The display whose Desktops are being edited, as its Spaces store it: a signature, a name in
    /// older profiles, or nil for profiles from before multi-display. Starts on the main display.
    private var display: String? {
        if let selectedDisplay { return selectedDisplay }
        if let recorded = profile.displays {
            return (recorded.first { $0.frame.origin == .zero } ?? recorded.first)?.identity.signature
        }
        return profile.recordedDisplays.first?.signature
    }

    /// How many Desktops the edited display had when captured, or the most any display has now.
    private var desktopCount: Int {
        profile.displays?.first { $0.identity.signature == display }?.desktops ?? model.spaceCount
    }

    /// Whether a profile Space is Desktop `number` on the display being edited.
    private func isHere(_ snapshot: SpaceSnapshot, _ number: Int) -> Bool {
        snapshot.space == number && snapshot.display == display
    }

    /// The selected Space's configuration, or an empty one the first edit will add to the profile.
    private var space: SpaceSnapshot {
        let first = profile.spaces.filter { spanning || $0.display == display }.map(\.space).min() ?? 1
        let number = min(selectedSpace ?? first, max(desktopCount, 1))
        return profile.spaces.first { isHere($0, number) } ?? Self.unconfigured(number, display: display, model: model)
    }

    static func unconfigured(_ number: Int, display: String?, model: SettingsModel) -> SpaceSnapshot {
        SpaceSnapshot(space: number, mode: model.settings.spaceRules.layout(forSpace: number), tree: .tile([]),
                      floating: [], others: [], display: display)
    }

    /// The displays the profile records, as captured. Empty for profiles that only name them.
    private var recorded: [ProfileDisplay] { profile.displays ?? [] }

    /// One Desktop across every display: chosen first, then edited on each display at once.
    private var spanning: Bool { profile.spansDisplays == true && recorded.count > 1 }

    /// A display's shape as captured, or the main screen's.
    private func frame(of display: String?) -> CGRect {
        recorded.first { $0.identity.signature == display }?.frame ?? (NSScreen.main ?? NSScreen.screens[0]).frame
    }

    /// The selected Desktop on each display it has a part on: one part, or every display when spanning.
    private var parts: [DesktopPart] {
        let number = space.space
        let displays: [String?] = spanning ? recorded.map(\.identity.signature) : [display]
        return displays.map { display in
            let snapshot = profile.spaces.first { $0.space == number && $0.display == display }
            return DesktopPart(display: display, name: recorded.first { $0.identity.signature == display }?.identity.name,
                               frame: frame(of: display),
                               snapshot: snapshot ?? Self.unconfigured(number, display: display, model: model),
                               configured: snapshot != nil)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                desktops
                SpaceDesigner(model: model, profile: profile, label: model.settings.spaceRules.labels[space.space],
                              parts: parts, selected: display, select: { selectedDisplay = $0 })
                whenApplied
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button { choosingIcon = true } label: {
                        Image(systemName: profile.symbol).font(.title2)
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .help("Choose an icon for this profile")
                    .accessibilityLabel("Profile icon")
                    .popover(isPresented: $choosingIcon, arrowEdge: .bottom) {
                        ProfileIconPicker(selected: profile.symbol) { symbol in
                            var updated = profile
                            updated.setIcon(symbol)
                            model.update(updated, action: "Change Profile Icon")
                            choosingIcon = false
                        }
                    }
                    Text(profile.name).font(.title2.weight(.semibold))
                    Button { renaming = true } label: { Label("Rename", systemImage: "pencil").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless).help("Rename")
                }
                Text(summary).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply Profile") { model.load(profile) }
                .help("Arrange your Desktops as this profile describes")
        }
        .sheet(isPresented: $renaming) { RenameSheet(model: model, profile: profile) }
    }

    private var summary: String {
        let windows = profile.spaces.flatMap(\.windows).count
        let desktops = Set(profile.spaces.map(\.space)).count
        let displays = recorded.map(\.identity.name)
        let fullScreen = profile.fullScreen?.count ?? 0
        return ["\(desktops) Desktop\(desktops == 1 ? "" : "s")", "\(windows) window\(windows == 1 ? "" : "s")",
                fullScreen > 0 ? "\(fullScreen) full screen" : nil,
                displays.isEmpty ? nil : displays.joined(separator: " + ")].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Desktops

    /// Where to start: separate Spaces pick a display then one of its Desktops; spanning Spaces pick
    /// the Desktop, which the card below shows on every display.
    private var desktops: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Desktops").font(.headline)
                Text(spanning ? "Your Desktops span every display. Choose one to arrange it on each display."
                     : recorded.count > 1 || profile.recordedDisplays.count > 1 ? "Each display has its own Desktops. Choose a display, then a Desktop to arrange."
                     : "Choose a Desktop to arrange.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !spanning { displayPicker }
            spaceChips
        }
    }

    /// Several displays with their own Desktops: drawn where they sat when captured (or a picker for
    /// older profiles, which only name them).
    @ViewBuilder private var displayPicker: some View {
        if recorded.count > 1 {
            // In a well, as System Settings ▸ Displays ▸ Arrange shows them
            ArrangementStrip(items: recorded.map { .init(id: $0.identity.signature, name: $0.identity.name, frame: $0.frame) },
                             selected: display, select: { selectedDisplay = $0; selectedSpace = nil }, height: 64)
                .padding(.vertical, 12).padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
        } else if profile.displays == nil, profile.recordedDisplays.count > 1 {
            Picker("Display", selection: Binding(get: { display ?? "" }, set: { selectedDisplay = $0; selectedSpace = nil })) {
                ForEach(profile.recordedDisplays, id: \.signature) { Text($0.name).tag($0.signature) }
            }
            .pickerStyle(.segmented).fixedSize()
        }
    }

    /// Whether the profile arranges Desktop `number` here: on the chosen display, or on any display
    /// when spanning.
    private func arranges(_ number: Int) -> SpaceSnapshot? {
        profile.spaces.first { $0.space == number && (spanning || $0.display == display) }
    }

    /// A pill for every Desktop: filled with a window count when the profile arranges it, outlined
    /// with + when it doesn't. Drop an app from a tile onto one to move it there.
    private var spaceChips: some View {
        let labels = model.settings.spaceRules.labels
        return FlowLayout(spacing: 8) {
            ForEach(1...max(desktopCount, 1), id: \.self) { number in
                let configured = arranges(number)
                let isSelected = number == space.space
                Button { selectedSpace = number } label: {
                    HStack(spacing: 5) {
                        if configured == nil { Image(systemName: "plus").font(.caption2.weight(.semibold)) }
                        Text([String(number), labels[number]].compactMap { $0 }.joined(separator: " "))
                            .lineLimit(1).fixedSize()
                        let count = profile.spaces.filter { $0.space == number && (spanning || $0.display == display) }.flatMap(\.windows).count
                        if count > 0 { Text("\(count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                    .foregroundStyle(configured == nil && !isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                               : configured == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary)))
                    .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : .secondary.opacity(configured == nil ? 0.4 : 0),
                                                    style: StrokeStyle(lineWidth: 1, dash: configured == nil && !isSelected ? [3, 2] : [])))
                }
                .buttonStyle(.plain)
                .help(configured == nil ? "Not in this profile yet: applying it leaves this Desktop as it is" : "Arranged by this profile")
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, let move = TileDrag(item) else { return false }
                    moveApps(from: move.space, path: move.path, to: number)
                    return true
                }
            }
        }
    }

    // MARK: When applied

    /// How the profile behaves when it's applied, after what it arranges.
    private var whenApplied: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When applied").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Show afterwards").foregroundStyle(.secondary)
                    Picker("", selection: binding(\.show)) {
                        Text("Stay where I am").tag(Int?.none)
                        ForEach(1...model.spaceCount, id: \.self) { Text("Desktop \($0)").tag(Int?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Apps not in the profile").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: Binding(get: { profile.quitUnlisted == true ? 2 : profile.hideUnlisted == true ? 1 : 0 }, set: {
                            var updated = profile
                            updated.hideUnlisted = $0 == 1 ? true : nil
                            updated.quitUnlisted = $0 == 2 ? true : nil
                            model.update(updated)
                        })) {
                            Text("Leave running").tag(0)
                            Text("Hide").tag(1)
                            Text("Quit (asks first)").tag(2)
                        }
                        .labelsHidden().fixedSize()
                        // What hide or quit would do if the profile were applied now, so it can't surprise
                        if profile.quitUnlisted == true || profile.hideUnlisted == true {
                            let names = WindowManager.unlistedApps(for: profile).compactMap(\.localizedName).sorted()
                            Text(names.isEmpty ? "Every running app is in this profile."
                                 : "Applying it now would \(profile.quitUnlisted == true ? "quit" : "hide") \(names.formatted(.list(type: .and))).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Shortcut").foregroundStyle(.secondary)
                    ProfileShortcut(model: model, command: "load \(profile.name)")
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Apply automatically").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("When these displays are connected", isOn: Binding(get: { profile.autoApply == true }, set: { on in
                            var updated = profile
                            updated.autoApply = on ? true : nil
                            // A profile designed from scratch has no displays yet: it takes the ones connected now
                            if on, updated.displays == nil, updated.display == nil {
                                let desktops = Spaces.desktops
                                updated.displays = desktops.displays.map { ProfileDisplay(identity: $0.identity, frame: $0.frame, desktops: $0.spaces.count) }
                                updated.display = desktops.fingerprint
                                updated.spansDisplays = desktops.spansDisplays ? true : nil
                            }
                            model.update(updated)
                        }))
                        Text(autoApplyNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("On the displays now").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(placementNotes.enumerated()), id: \.offset) { _, note in
                            Label(note.text, systemImage: note.symbol).font(.caption)
                                .foregroundStyle(note.problem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
            OpenOnLaunch(model: model, profile: profile)
        }
    }

    /// Moves a tile's apps to another Space: they leave an empty slot behind and take the target's
    /// first empty slot, or stack on its last tile.
    private func moveApps(from source: Int, path: TilePath, to target: Int) {
        guard source != target, let from = profile.spaces.firstIndex(where: { isHere($0, source) }),
              case .tile(let refs)? = profile.spaces[from].tree?.node(at: path), !refs.isEmpty else { return }
        var updated = profile
        updated.spaces[from].tree = updated.spaces[from].tree?.replacing(at: path, with: .tile([]))
        if let to = updated.spaces.firstIndex(where: { isHere($0, target) }) {
            updated.spaces[to].tree = (updated.spaces[to].tree ?? .tile([])).filled(with: refs)
        } else {
            var space = Self.unconfigured(target, display: display, model: model)
            space.tree = .tile(refs)
            updated.spaces.append(space)
        }
        model.update(updated)
    }

    /// The displays the profile names, for sentences about them.
    private var displayNames: String {
        let names = profile.displays?.map(\.identity.name) ?? profile.display.map { [$0] } ?? []
        return names.isEmpty ? "" : names.map { "“\($0)”" }.joined(separator: " and ")
    }

    private var autoApplyNote: String {
        if profile.autoApply != true, profile.displays == nil, let display = profile.display {
            return "Before this setting, it applied when “\(display)” was connected. Turn it on to keep that."
        }
        if displayNames.isEmpty { return "Turning this on records the displays connected now." }
        let mode = profile.spansDisplays == true ? "Spaces spanning displays" : "each display with its own Spaces"
        return "Applies when exactly \(displayNames) \(profile.displays?.count ?? 1 > 1 ? "are" : "is") connected, and no other display, with \(mode)."
    }

    /// Where each Space lands on the displays connected now: one line when everything lands at
    /// home, otherwise a line per Space that moves or has nowhere to go.
    private var placementNotes: [(text: String, symbol: String, problem: Bool)] {
        let desktops = Spaces.desktops
        let placements = desktops.place(profile)
        let moved = placements.filter { $0.reason != .matched }
        // Captured in the other Spaces mode: it still applies by hand, but never by itself
        let mode: [(text: String, symbol: String, problem: Bool)] = desktops.sameMode(as: profile) ? [] : [(
            profile.spansDisplays == true
                ? "Captured with Spaces spanning displays; each display has its own Spaces now, so it won't apply by itself."
                : "Captured with each display having its own Spaces; they span displays now, so it won't apply by itself.",
            "rectangle.on.rectangle.slash", true)]
        guard !moved.isEmpty else { return mode + [("Every Space lands on its own display.", "checkmark.circle", false)] }
        return mode + moved.map { placement in
            let from = profile.displays?.first { $0.identity.signature == placement.snapshot.display }?.identity.name
                ?? placement.snapshot.display
            let to = placement.display?.name ?? "the main display"
            let desktop = "Desktop \(placement.snapshot.space)" + (from.map { " of \($0)" } ?? "")
            switch placement.reason {
            case .appended:
                return ("\(desktop) goes to Desktop \(placement.number) of \(to), where macOS moved \(from ?? "its display")'s Desktops.",
                        "arrow.turn.down.right", false)
            case .noRoom:
                let count = placement.display?.spaces.count ?? 0
                return ("\(desktop) is skipped: \(to) has \(count) Desktop\(count == 1 ? "" : "s"). Add more in Mission Control to place its windows.",
                        "exclamationmark.triangle", true)
            case .matched:
                return ("", "", false)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        Binding(get: { profile[keyPath: keyPath] }, set: {
            var updated = profile
            updated[keyPath: keyPath] = $0
            model.update(updated)
        })
    }
}

// MARK: - Open on launch

/// Advanced, and folded away until opened: links, files, folders and commands to open in each app
/// when applying the profile launches it.
private struct OpenOnLaunch: View {
    var model: SettingsModel
    let profile: Profile
    @State private var expanded = false

    /// The profile's apps, and any others it opens things in, by name. Finder is always running,
    /// so applying never launches it.
    private var apps: [(id: String, name: String)] {
        profile.apps.union(profile.open.map { Array($0.keys) } ?? []).subtracting(["com.apple.finder"])
            .map { (id: $0, name: InstalledApps.name(forBundleID: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let count = profile.open?.values.joined().count ?? 0
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("When applying the profile launches an app, it opens these too, one per line: a link, a file or folder (starting / or ~), or a command (starting $) for a terminal app. Apps that are already running are left as they are, and an app that restores its own windows keeps them: a browser gets a new tab.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if apps.isEmpty {
                    Text("Add apps to the profile's Desktops first.").font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(apps, id: \.id) { app in
                        GridRow(alignment: .firstTextBaseline) {
                            Label { Text(app.name) } icon: {
                                Image(nsImage: AppIcons.icon(for: app.name)).resizable().frame(width: 16, height: 16)
                            }
                            LaunchItemsField(saved: profile.open?[app.id] ?? []) { lines in
                                var updated = profile
                                updated.setItems(lines, opening: app.id)
                                if updated != profile { model.update(updated, action: "Change Items to Open") }
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Advanced").font(.headline)
                if count > 0 && !expanded {
                    Text("Opens \(count) item\(count == 1 ? "" : "s") when launching apps").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One app's lines. Saved when focus leaves, so typing doesn't write the file, or add an undo step,
/// on every key.
private struct LaunchItemsField: View {
    let saved: [String]
    let save: ([String]) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(saved: [String], save: @escaping ([String]) -> Void) {
        self.saved = saved
        self.save = save
        _text = State(initialValue: saved.joined(separator: "\n"))
    }

    private var lines: [String] { text.components(separatedBy: .newlines) }

    var body: some View {
        // A text editor, not a field, so Return starts a new line
        TextEditor(text: $text)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: 44, maxHeight: 110)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("https://…, ~/folder or $ command").font(.body.monospaced()).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
            .focused($focused)
            .onChange(of: focused) { if !focused { save(lines) } }
            .onDisappear { save(lines) }
            // Undo, or an edit to the file, changes what's saved underneath
            .onChange(of: saved) { if !focused { text = saved.joined(separator: "\n") } }
    }
}

// MARK: - One Desktop

/// A Desktop's part on one display: its layout in the profile, or an empty one the first edit adds.
private struct DesktopPart {
    let display: String?
    let name: String?
    let frame: CGRect
    let snapshot: SpaceSnapshot
    let configured: Bool
}

/// The selected Desktop as a card: what it's called, how it lays windows out, a template to start
/// from, and the picture to edit. When Spaces span displays, every display's part shows where the
/// display sits; the layout controls act on the selected one.
private struct SpaceDesigner: View {
    var model: SettingsModel
    let profile: Profile
    let label: String?
    let parts: [DesktopPart]
    let selected: String?
    let select: (String?) -> Void

    private var edited: DesktopPart { parts.first { $0.display == selected } ?? parts[0] }
    private var space: SpaceSnapshot { edited.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            title
            if !parts.contains(where: \.configured) {
                Label("This profile doesn't arrange Desktop \(space.space) yet, so applying it leaves the Desktop as it is. Choose a template or an app to start.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            controls
            canvas
            Text(parts.count > 1 ? "Click a display's part to edit it. Click a tile to choose its app or split it; drag the gaps between tiles to resize."
                 : "Click a tile to choose its app or split it; drag the gaps between tiles to resize.")
                .font(.caption).foregroundStyle(.secondary)
            AppList(title: "Floating", detail: "On this Desktop but not tiled",
                    apps: space.floating.map(\.app)) { apps in update(edited) { $0.floating = apps.map { WindowRef(app: $0, index: 0) } } }
            if !space.others.isEmpty {
                AppList(title: "Also on this Desktop", detail: "Captured here before it was laid out; moved here and tiled as usual",
                        apps: space.others.map(\.app)) { apps in update(edited) { $0.others = apps.map { WindowRef(app: $0, index: 0) } } }
            }
        }
        .padding(16)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Which Desktop, on which display, and the menu that clears it.
    private var title: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(["Desktop \(space.space)", label].compactMap { $0 }.joined(separator: " · ")).font(.title3.weight(.semibold))
                if let place = placeDescription { Text(place).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            Menu {
                if parts.count > 1 {
                    Button("Clear \(edited.name ?? "This Display")'s Part", role: .destructive) { clear([edited]) }
                        .disabled(!edited.configured)
                }
                Button("Clear This Desktop", role: .destructive) { clear(parts) }
                    .disabled(!parts.contains(where: \.configured))
            } label: {
                Label("Desktop actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Clearing forgets this Desktop's layout in the profile; the Desktop itself is untouched")
        }
    }

    private var placeDescription: String? {
        if parts.count > 1 { return "Across \(parts.compactMap(\.name).joined(separator: " and ")), editing \(edited.name ?? "one display")" }
        return edited.name.map { "On \($0)" }
    }

    /// The layout mode with words, then templates to start from when it tiles.
    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow(alignment: .firstTextBaseline) {
                Text("Layout").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Layout", selection: Binding(get: { space.mode }, set: { mode in update(edited) { $0.mode = mode } })) {
                        ForEach([LayoutMode.bsp, .stack, .float], id: \.self) { mode in
                            Label(Self.modeName(mode), systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Text(Self.modeDetail(space.mode)).font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow(alignment: .top) {
                Text("Start from").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(LayoutSnapshot.templates, id: \.name) { template in
                        TemplateButton(layout: template.layout, name: template.name) {
                            // Keeps this part's windows, moving them into the template's slots in order
                            update(edited) { $0.tree = template.layout.filled(with: $0.tree.map(Self.refs) ?? []) }
                        }
                        // Stack and Float don't tile, so a split layout has nothing to shape
                        .disabled(space.mode != .bsp)
                    }
                }
            }
        }
    }

    static func modeName(_ mode: LayoutMode) -> String {
        switch mode {
        case .bsp: "Tile"
        case .stack: "Stack"
        case .float: "Float"
        }
    }

    static func modeDetail(_ mode: LayoutMode) -> String {
        switch mode {
        case .bsp: "Windows sit side by side and fill the Desktop."
        case .stack: "Every window fills the Desktop; the stack keys switch between them."
        case .float: "Windows stay where you put them."
        }
    }

    /// One part fills the card at its display's shape; several sit where their displays do.
    @ViewBuilder private var canvas: some View {
        if parts.count == 1 {
            partCanvas(parts[0])
                .aspectRatio(parts[0].frame.width / max(parts[0].frame.height, 1), contentMode: .fit)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        } else {
            let area = parts.reduce(CGRect.null) { $0.union($1.frame) }
            GeometryReader { geometry in
                let fitted = Arrangement.fit(parts.map(\.frame), in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        let rect = fitted[index].insetBy(dx: 4, dy: 4)
                        partCanvas(part)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(part.display == edited.display ? Color.accentColor : .clear, lineWidth: 2))
                            .simultaneousGesture(TapGesture().onEnded { select(part.display) })
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            .aspectRatio(area.width / max(area.height, 1), contentMode: .fit)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private func partCanvas(_ part: DesktopPart) -> some View {
        LayoutCanvas(model: model, space: part.snapshot.space, tree: part.snapshot.tree ?? .tile([]),
                     wallpaper: Wallpaper.image(for: part.display)) { tree in update(part) { $0.tree = tree } }
    }

    private func clear(_ cleared: [DesktopPart]) {
        var updated = profile
        updated.spaces.removeAll { snapshot in cleared.contains { $0.snapshot.space == snapshot.space && $0.display == snapshot.display } }
        model.update(updated)
    }

    /// Changes one part of the Desktop, adding it to the profile on its first edit.
    private func update(_ part: DesktopPart, _ change: (inout SpaceSnapshot) -> Void) {
        var updated = profile
        let isThis = { (snapshot: SpaceSnapshot) in snapshot.space == part.snapshot.space && snapshot.display == part.display }
        if !updated.spaces.contains(where: isThis) { updated.spaces.append(part.snapshot) }
        let index = updated.spaces.firstIndex(where: isThis)!
        change(&updated.spaces[index])
        model.update(updated)
    }

    static func refs(_ node: LayoutSnapshot) -> [WindowRef] {
        switch node {
        case .tile(let refs): refs
        case let .split(_, _, first, second): refs(first) + refs(second)
        }
    }
}

/// The Space as a little screen: tiles you can click to edit, gaps you can drag to resize.
private struct LayoutCanvas: View {
    var model: SettingsModel
    let space: Int
    let tree: LayoutSnapshot
    /// The display's wallpaper, behind the tiles as on screen.
    let wallpaper: NSImage?
    let change: (LayoutSnapshot) -> Void
    @State private var editing: TilePath?
    /// The tree while a divider is being dragged, saved when the drag ends.
    @State private var dragging: LayoutSnapshot?

    private let gap: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let shown = dragging ?? tree
            let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 8, dy: 8)
            ZStack(alignment: .topLeading) {
                WallpaperFill(image: wallpaper, cornerRadius: 10)
                RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.4), lineWidth: 2)
                ForEach(shown.tiles(in: bounds, gap: gap), id: \.path) { tile in
                    TileView(model: model, refs: tile.refs, editing: editing == tile.path)
                        .frame(width: tile.rect.width, height: tile.rect.height)
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                        .onTapGesture { editing = tile.path }
                        .draggable(TileDrag(space: space, path: tile.path).text) {
                            HStack(spacing: -6) {
                                ForEach(Array(tile.refs.enumerated()), id: \.offset) { _, ref in
                                    Image(nsImage: AppIcons.icon(for: InstalledApps.name(forBundleID: ref.app))).resizable().frame(width: 32, height: 32)
                                }
                            }
                        }
                        .popover(isPresented: Binding(get: { editing == tile.path }, set: { if !$0 { editing = nil } })) {
                            TileMenu(model: model, tree: tree, path: tile.path) { tree in
                                editing = nil
                                change(tree)
                            }
                        }
                }
                ForEach(shown.dividers(in: bounds, gap: gap), id: \.path) { divider in
                    DividerHandle(axis: divider.axis)
                        .frame(width: divider.strip.width + (divider.axis == .horizontal ? 6 : 0),
                               height: divider.strip.height + (divider.axis == .vertical ? 6 : 0))
                        .offset(x: divider.strip.minX - (divider.axis == .horizontal ? 3 : 0),
                                y: divider.strip.minY - (divider.axis == .vertical ? 3 : 0))
                        .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                            let along = divider.axis == .horizontal
                                ? (drag.location.x - divider.bounds.minX) / divider.bounds.width
                                : (drag.location.y - divider.bounds.minY) / divider.bounds.height
                            dragging = (dragging ?? tree).settingRatio(at: divider.path, to: Double(along))
                        }.onEnded { _ in
                            if let dragging { change(dragging) }
                            dragging = nil
                        }, including: .gesture)
                }
            }
            .coordinateSpace(name: "canvas")
        }
    }
}

private struct TileView: View {
    var model: SettingsModel
    let refs: [WindowRef]
    let editing: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            // Frosted, so the tile reads over any wallpaper
            RoundedRectangle(cornerRadius: 6).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(hovering || editing ? 0.15 : 0))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(editing ? Color.accentColor : .secondary.opacity(0.4), lineWidth: editing ? 2 : 1)
            if refs.isEmpty {
                Label("Choose app", systemImage: "plus.circle").font(.caption).foregroundStyle(.secondary)
            } else if let preview = refs.lazy.compactMap({ model.liveWindows[$0].flatMap { WindowPreviews.shared.images[$0] } }).first {
                // The running window's content, named by its app; apps not running keep their icon
                Color.clear
                    .overlay { Image(decorative: preview, scale: 2).resizable().aspectRatio(contentMode: .fill) }
                    .clipShape(RoundedRectangle(cornerRadius: 6)).padding(1)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 4) {
                            ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                                Image(nsImage: AppIcons.icon(for: InstalledApps.name(forBundleID: ref.app))).resizable().frame(width: 16, height: 16)
                            }
                            Text(refs.map { InstalledApps.name(forBundleID: $0.app) }.joined(separator: ", ")).font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                    }
            } else {
                VStack(spacing: 4) {
                    HStack(spacing: -6) {
                        ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                            Image(nsImage: AppIcons.icon(for: InstalledApps.name(forBundleID: ref.app))).resizable().frame(width: 32, height: 32)
                        }
                    }
                    Text(refs.map { InstalledApps.name(forBundleID: $0.app) }.joined(separator: ", "))
                        .font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    if refs.count > 1 { Text("stacked").font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// What clicking a tile offers: choose its app, add one to stack, split, clear or remove.
private struct TileMenu: View {
    var model: SettingsModel
    let tree: LayoutSnapshot
    let path: TilePath
    let change: (LayoutSnapshot) -> Void

    private var refs: [WindowRef] {
        if case .tile(let refs)? = tree.node(at: path) { refs } else { [] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppMenu(model: model, title: refs.isEmpty ? "Choose App" : "Replace App") { id in
                change(tree.replacing(at: path, with: .tile([WindowRef(app: id, index: 0)])))
            }
            if !refs.isEmpty {
                AppMenu(model: model, title: "Stack Another App Here") { id in
                    change(tree.replacing(at: path, with: .tile(refs + [WindowRef(app: id, index: 0)])))
                }
            }
            Divider()
            Button { change(tree.splitting(at: path, along: .horizontal)) } label: { Label("Split Left | Right", systemImage: "rectangle.split.2x1") }
            Button { change(tree.splitting(at: path, along: .vertical)) } label: { Label("Split Top / Bottom", systemImage: "rectangle.split.1x2") }
            Divider()
            if !refs.isEmpty {
                Button { change(tree.replacing(at: path, with: .tile([]))) } label: { Label("Clear App", systemImage: "xmark.circle") }
            }
            Button(role: .destructive) { change(tree.removing(at: path)) } label: { Label("Remove Tile", systemImage: "trash") }
                .disabled(path.isEmpty && refs.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
    }
}

/// Running apps first, then everything installed. Calls back with the chosen app's bundle ID.
private struct AppMenu: View {
    var model: SettingsModel
    let title: String
    let choose: (String) -> Void

    var body: some View {
        Menu(title) {
            Section("Running") { items(model.runningApps) }
            Section("All Applications") { items(model.installedApps.filter { !model.runningApps.contains($0) }) }
        }
        .fixedSize()
    }

    private func items(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            if let id = InstalledApps.bundleID(forName: name) {
                Button { choose(id) } label: { Label { Text(name) } icon: { Image(nsImage: AppIcons.icon(for: name)) } }
            }
        }
    }
}

private struct DividerHandle: View {
    let axis: Axis
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.accentColor.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                (inside ? (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
            }
    }
}

/// A row of app chips with remove buttons and an add menu.
private struct AppList: View {
    let title: String
    let detail: String
    let apps: [String]
    let change: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                    let name = InstalledApps.name(forBundleID: app)
                    HStack(spacing: 4) {
                        Image(nsImage: AppIcons.icon(for: name)).resizable().frame(width: 16, height: 16)
                        Text(name).font(.caption)
                        Button { var updated = apps; updated.remove(at: index); change(updated) } label: {
                            Label("Remove \(name)", systemImage: "xmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain).help("Remove \(name)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                }
                Menu {
                    ForEach(InstalledApps.names, id: \.self) { name in
                        if let id = InstalledApps.bundleID(forName: name) {
                            Button { change(apps + [id]) } label: { Label { Text(name) } icon: { Image(nsImage: AppIcons.icon(for: name)) } }
                        }
                    }
                } label: { Label("Add App", systemImage: "plus").font(.caption) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Add an app")
            }
        }
    }
}

/// The profile's load shortcut, stored as a `load <name>` key binding, with the same controls as
/// the Keys tab: keycaps to re-record, × to clear, or a Record shortcut slot when there's none.
private struct ProfileShortcut: View {
    var model: SettingsModel
    let command: String

    var body: some View {
        let chords = model.chords(for: command)
        HStack(spacing: 6) {
            Image(systemName: "keyboard").foregroundStyle(.secondary).help("Shortcut that loads this profile")
            if chords.isEmpty { RecordSlot(model: model, command: command) }
            ForEach(chords, id: \.self) { ChordButton(model: model, chord: $0) }
        }
    }
}

/// A tile being dragged to another Space's chip, carried as text: "space:path" with the path as 0s and 1s.
private struct TileDrag {
    let space: Int
    let path: TilePath

    init(space: Int, path: TilePath) {
        self.space = space
        self.path = path
    }

    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let space = Int(parts[0]) else { return nil }
        self.init(space: space, path: parts[1].map { $0 == "1" })
    }

    var text: String { "\(space):" + path.map { $0 ? "1" : "0" }.joined() }
}

/// A template drawn as its splits; clicking applies it.
private struct TemplateButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let layout: LayoutSnapshot
    let name: String
    let apply: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: apply) {
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                for tile in layout.tiles(in: bounds, gap: 2) {
                    context.fill(Path(roundedRect: tile.rect, cornerRadius: 2), with: .color(hovering ? .accentColor : .secondary.opacity(0.6)))
                }
            }
            .frame(width: 34, height: 22)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor.opacity(0.15) : .clear))
            .frame(width: 58)
            .overlay(alignment: .bottom) {
                Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8).offset(y: 16)
            }
            .padding(.bottom, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 && isEnabled }
        .help(isEnabled ? "\(name): keeps this Desktop's apps, filling the new tiles in order"
                        : "Templates shape tiled Desktops; choose Tile above to use them")
    }
}
