import SpacetileCore
import SwiftUI

/// Every action Spacetile has, in the style of BetterStage's Shortcuts screen. Sections follow the
/// modifier families (⌥ focus, ⌥⇧ move, ⌥⌃ size, ⌥⇧⌃ preselect), and each section's picker
/// changes its prefix as a whole. Each row shows the action's picture, name and shortcut: click
/// the shortcut (or Record shortcut when unbound) and press the keys; × clears it. Bindings that
/// match no listed action appear under Custom so nothing is hidden.
struct KeysTab: View {
    @Bindable var model: SettingsModel
    @State private var confirmingRestore = false
    @State private var query = ""
    /// Another tool's shortcuts waiting for confirmation.
    @State private var preset: KeyPreset?

    private func matches(_ action: KeyAction) -> Bool {
        query.isEmpty || action.title.localizedCaseInsensitiveContains(query) || action.command.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        Form {
            Toggle(isOn: Binding(get: { model.settings.usesShortcuts }, set: { model.settings.shortcuts = $0; model.save() })) {
                Text("Use Spacetile's shortcuts")
                Text("Turn off to bind Spacetile's commands in Raycast, skhd or Karabiner-Elements instead. The shortcuts below are kept for when you turn this back on.")
            }
            Text("Click a shortcut or Record shortcut, then press the keys; Esc cancels. × clears a shortcut. ⚠︎ means another app already owns it.")
                .font(.callout).foregroundStyle(.secondary)
            if query.isEmpty || "switch send space".localizedCaseInsensitiveContains(query) { SpacesSection(model: model) }
            ForEach(KeyAction.sections, id: \.title) { section in
                let shown = section.actions.filter(matches)
                if !shown.isEmpty {
                    ActionSection(model: model, title: section.title, symbol: section.symbol, actions: section.actions,
                                  shown: shown, filtering: !query.isEmpty)
                }
            }
            CustomSection(model: model, query: query)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                HStack {
                    TextField("Search actions", text: $query, prompt: Text("Search actions, e.g. swap or stack"))
                        .textFieldStyle(.roundedBorder)
                    // For people coming from another window manager: its defaults, mapped onto Spacetile
                    Menu("Use Shortcuts From") {
                        ForEach(KeyPreset.all) { preset in Button(preset.name) { self.preset = preset } }
                        Divider()
                        Button("Spacetile (defaults)") { confirmingRestore = true }
                    }
                    .fixedSize()
                    .help("Use another window manager's default shortcuts where Spacetile has the same action")
                }
                if let notice = model.notice {
                    HStack(alignment: .firstTextBaseline) {
                        Label(notice, systemImage: "info.circle.fill").symbolRenderingMode(.multicolor)
                        Spacer()
                        if model.undo.canUndo { Button("Undo") { model.undo.undo(); model.notice = nil } }
                        Button("OK") { model.notice = nil }
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
        .safeAreaInset(edge: .bottom) { RestoreDefaultsBar { confirmingRestore = true } }
        // Every shortcut at once is the one reset worth a second look, though Undo still takes it back
        .confirmationDialog("Restore every shortcut to its default?", isPresented: $confirmingRestore) {
            Button("Restore All Shortcuts") { model.restoreDefaults(.keys) }
        } message: {
            Text("Shortcuts you recorded or changed, including ones that apply profiles, are replaced. Edit › Undo takes this back.")
        }
        .confirmationDialog("Use \(preset?.name ?? "")'s shortcuts?", isPresented: Binding(get: { preset != nil }, set: { if !$0 { preset = nil } }),
                            presenting: preset) { preset in
            Button("Use \(preset.name) Shortcuts") { model.apply(preset) }
        } message: { preset in
            Text("\(preset.note) Spacetile's own shortcuts stay for actions \(preset.name) doesn't have"
                 + (preset.fallbacks.isEmpty ? "" : "; the few whose keys \(preset.name) uses move to new ones in its style")
                 + ". Shortcuts you recorded are replaced. Edit › Undo takes this back.")
        }
    }
}

extension KeyChord {
    /// As menus show it, e.g. ⌥⇧F.
    var symbols: String { modifierSymbols(modifiers) + ChordButton.keyName(key) }
}

extension SpacetileCore.Settings {
    /// The current keys for a group of commands as one label, e.g. "⌥F", "⌥ H J K L" or "⌥⇧ 1…0",
    /// or nil if none of them is bound. Copy that names a key uses this, so it follows rebinding.
    func shortcutText(_ commands: [String]) -> String? {
        let chords = commands.compactMap { command in keys.filter { $0.value == command }.keys.sorted().first.flatMap(KeyChord.init) }
        guard chords.count > 1 else { return chords.first?.symbols }
        guard Set(chords.map(\.modifiers)).count == 1 else { return chords.map(\.symbols).joined(separator: " ") }
        let names = chords.map { ChordButton.keyName($0.key) }
        let list = names.count > 4 ? "\(names[0])…\(names[names.count - 1])" : names.joined(separator: " ")
        return modifierSymbols(chords[0].modifiers) + " " + list
    }
}

func modifierSymbols(_ modifiers: Set<KeyChord.Modifier>) -> String {
    let symbols: [KeyChord.Modifier: String] = [.ctrl: "⌃", .alt: "⌥", .shift: "⇧", .cmd: "⌘"]
    return KeyChord.Modifier.allCases.filter(modifiers.contains).map { symbols[$0]! }.joined()
}

// MARK: - Sections

/// Switch to and send to Space N: one shared modifier each, then the number keys.
private struct SpacesSection: View {
    var model: SettingsModel

    var body: some View {
        Section {
            row("Switch to Space", command: "space")
            row("Send to Space", command: "send")
        } header: {
            Label("Spaces", systemImage: "rectangle.3.group")
        }
    }

    private func row(_ title: String, command: String) -> some View {
        // Keycaps only for Spaces that exist. The prefix applies to all ten, so bindings kept for
        // Spaces not created yet match when they are.
        let all = (1...10).map { "\(command) \($0)" }
        let commands = Array(all.prefix(model.spaceCount))
        return HStack {
            Text(title)
            Spacer()
            ModifierPicker(model: model, commands: all)
            Text("+").foregroundStyle(.secondary)
            ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                let chord = model.chords(for: command).first
                Keycap(text: chord.flatMap { KeyChord($0)?.key } ?? String((index + 1) % 10), dimmed: chord == nil)
                    .help(chord == nil ? "Not bound" : "\(command): \(chord!)")
            }
        }
    }
}

private struct ActionSection: View {
    var model: SettingsModel
    let title: String
    let symbol: String
    let actions: [KeyAction]
    /// The actions matching the search; all of them when there's none.
    var shown: [KeyAction]
    /// Searching opens every section, so matches can't hide in a collapsed one.
    var filtering = false
    @State private var expanded = true

    var body: some View {
        Section {
            if expanded || filtering { rows }
        } header: {
            SectionToggle(expanded: $expanded) {
                Label(title, systemImage: symbol)
                Spacer()
                let changed = model.changedCount(actions.map(\.command))
                if changed > 0 { Badge(text: "\(changed) changed") }
                Badge(text: "\(actions.count)")
            }
        }
    }

    @ViewBuilder private var rows: some View {
            HStack {
                VStack(alignment: .leading) {
                    Text("Prefix")
                    Text("Changes the modifiers of every action below that uses this prefix; the keys stay the same")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ModifierPicker(model: model, commands: boundCommands)
                Button("Restore") { model.restoreDefaultKeys(for: actions.map(\.command)) }
                    .disabled(model.changedCount(actions.map(\.command)) == 0)
                    .help("Give this section's actions their default shortcuts back")
            }
            ForEach(shown) { action in
                ActionRow(model: model, action: action)
            }
    }

    /// The modifier picker applies to the actions that share the most common modifiers.
    private var boundCommands: [String] {
        let bound = actions.map(\.command).filter { !model.chords(for: $0).isEmpty }
        let counts = Dictionary(grouping: bound.flatMap { model.chords(for: $0) }.compactMap { KeyChord($0)?.modifiers }, by: { $0 }).mapValues(\.count)
        guard let common = counts.max(by: { $0.value < $1.value })?.key else { return [] }
        return bound.filter { command in model.chords(for: command).allSatisfy { KeyChord($0)?.modifiers == common } }
    }
}

/// Bindings whose command isn't in the catalogue, e.g. `load meeting`.
private struct CustomSection: View {
    var model: SettingsModel
    var query = ""

    var body: some View {
        let custom = model.settings.keys.filter { !KeyAction.listedCommands.contains($0.value) }.sorted { $0.key < $1.key }
            .filter { query.isEmpty || $0.value.localizedCaseInsensitiveContains(query) }
        if !custom.isEmpty {
            Section {
                ForEach(custom, id: \.key) { chord, command in
                    HStack {
                        Image(systemName: "terminal").frame(width: 28)
                        Text(command).font(.body.monospaced())
                        Spacer()
                        ChordButton(model: model, chord: chord)
                    }
                }
            } header: {
                Label("Custom", systemImage: "terminal")
            }
        }
    }
}

// MARK: - Rows and pieces

private struct ActionRow: View {
    var model: SettingsModel
    let action: KeyAction

    var body: some View {
        HStack(spacing: 10) {
            ActionPicture(picture: action.picture).frame(width: 28, height: 20)
            Text(action.title)
            Spacer()
            let chords = model.chords(for: action.command)
            if chords.isEmpty {
                RecordSlot(model: model, command: action.command)
            }
            ForEach(chords, id: \.self) { chord in
                ChordButton(model: model, chord: chord)
            }
        }
    }
}

/// A section header that is one big target: the whole row toggles the section, highlights on
/// hover, and its chevron turns to show the state.
private struct SectionToggle<Content: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
                content()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "Collapse" : "Expand")
    }
}

/// An unbound action's empty shortcut field: click, then press the keys.
struct RecordSlot: View {
    var model: SettingsModel
    let command: String

    var body: some View {
        let recording = model.recording == .add(command)
        Button {
            recording ? model.stopRecording() : model.record(.add(command))
        } label: {
            Text(recording ? "Press keys…" : "Record shortcut")
                .font(.caption).foregroundStyle(recording ? .primary : .secondary)
                .padding(.horizontal, 8).frame(minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: recording ? [] : [3])).foregroundStyle(.tertiary))
        }
        .buttonStyle(.plain)
    }
}

/// A recorded chord as keycaps: click to re-record, × to clear it.
struct ChordButton: View {
    var model: SettingsModel
    let chord: String

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.recording == .chord(chord) ? model.stopRecording() : model.record(.chord(chord))
            } label: {
                if model.recording == .chord(chord) {
                    Keycap(text: "Press keys…", dimmed: false)
                } else if let parsed = KeyChord(chord) {
                    HStack(spacing: 2) {
                        ForEach(KeyChord.Modifier.allCases.filter(parsed.modifiers.contains), id: \.self) { Keycap(text: modifierSymbols([$0]), dimmed: false) }
                        Keycap(text: Self.keyName(parsed.key), dimmed: false)
                    }
                } else {
                    Keycap(text: chord, dimmed: true)
                }
            }
            .buttonStyle(.plain)
            if let problem = model.registrations[chord]?.problem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(problem)
            }
            Button { model.remove(chord) } label: { Label("Remove shortcut", systemImage: "xmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.tertiary) }
                .buttonStyle(.plain).help("Remove \(chord)")
        }
    }

    static func keyName(_ key: String) -> String {
        ["left": "←", "right": "→", "up": "↑", "down": "↓", "space": "Space", "return": "↩", "tab": "⇥", "delete": "⌫", "escape": "⎋"][key] ?? key.uppercased()
    }
}

struct Keycap: View {
    let text: String
    let dimmed: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .opacity(dimmed ? 0.4 : 1)
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
    }
}

/// Records a new shared prefix for a group: click, hold the modifiers, release. Every command in
/// the group keeps its key and takes the new modifiers.
private struct ModifierPicker: View {
    var model: SettingsModel
    let commands: [String]

    var body: some View {
        let recording = model.recording == .prefix(commands)
        Button {
            recording ? model.stopRecording() : model.record(.prefix(commands))
        } label: {
            if recording {
                Keycap(text: "Hold modifiers, then release", dimmed: false)
            } else if let current = model.sharedModifiers(of: commands) {
                HStack(spacing: 2) {
                    ForEach(KeyChord.Modifier.allCases.filter(current.contains), id: \.self) { Keycap(text: modifierSymbols([$0]), dimmed: false) }
                }
            } else {
                Keycap(text: "Mixed", dimmed: true)
            }
        }
        .buttonStyle(.plain).disabled(commands.isEmpty).help("Click, then hold the new modifiers and release")
    }
}

/// An SF Symbol, or for a placement a little screen with the region the window will take filled
/// in, drawn from the same geometry the tiler uses.
private struct ActionPicture: View {
    let picture: KeyAction.Picture

    var body: some View {
        switch picture {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 15)).foregroundStyle(.secondary)
        case .region(let region):
            Canvas { context, size in
                let screen = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                context.stroke(Path(roundedRect: screen, cornerRadius: 3), with: .color(.secondary), lineWidth: 1.2)
                let area = screen.insetBy(dx: 2, dy: 2)
                let rect = region.rect(in: area, gap: 1)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.accentColor))
            }
        }
    }
}
