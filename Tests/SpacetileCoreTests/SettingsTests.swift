import Foundation
import Testing
@testable import SpacetileCore

@Suite struct SettingsDefaults {
    /// The Phase 1–2 hardcoded keymap as (key code, Carbon modifiers, command), plus later additions:
    /// the config defaults must match it exactly.
    static let hardcoded: [(UInt32, UInt32, Command)] = {
        let opt: UInt32 = 0x800, optShift: UInt32 = 0xA00, optCtrl: UInt32 = 0x1800
        let digits: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        let vim: [(UInt32, Direction)] = [(4, .west), (38, .south), (40, .north), (37, .east)]
        let keymap: [(UInt32, UInt32, Command)] = digits.enumerated().map { ($0.element, opt, Command.focusSpace($0.offset + 1)) }
            + digits.enumerated().map { ($0.element, optShift, .sendToSpace($0.offset + 1)) }
            + vim.map { ($0.0, opt, .focus($0.1)) } + vim.map { ($0.0, optShift, .swap($0.1)) }
        let layout: [(UInt32, UInt32, Command)] = [
            (6, opt, .toggleZoom), (46, opt, .toggleZoom), (3, opt, .toggleFloat),
            (1, opt, .setLayout(.stack)), (2, opt, .setLayout(.bsp)),
            (11, opt, .balance), (24, opt, .balance), (30, opt, .balance),
            (7, opt, .mirror(.vertical)), (16, opt, .mirror(.horizontal)), (15, opt, .rotate(.threeQuarter)),
            (45, opt, .cycleStack(forward: true)), (35, opt, .cycleStack(forward: false)),
        ]
        // Added after the yabai port
        let later: [(UInt32, UInt32, Command)] = vim.map { ($0.0, 0x1A00, .preselect($0.1)) }
            + [(14, opt, .toggleSplit), (47, opt, .stepSpace(forward: true)), (43, opt, .stepSpace(forward: false)), (50, opt, .lastSpace)]
        // The ⌥⌃ sizing family and ⌥⇧ sending, replacing the yabai border nudges and ⌥[
        let sizing: [(UInt32, UInt32, Command)] = [(4, Direction.west), (38, .south), (40, .north), (37, .east)].map { ($0.0, optCtrl, .place(.edge($0.1, fraction: nil))) }
            + [
                (16, optCtrl, .place(.corner(vertical: .north, horizontal: .west))), (32, optCtrl, .place(.corner(vertical: .north, horizontal: .east))),
                (11, optCtrl, .place(.corner(vertical: .south, horizontal: .west))), (45, optCtrl, .place(.corner(vertical: .south, horizontal: .east))),
                (8, optCtrl, .place(.center)), (126, optCtrl, .place(.column(span: nil))), (24, optCtrl, .resize(grow: true)), (27, optCtrl, .resize(grow: false)), (15, optCtrl, .restore),
                (47, optShift, .sendStep(forward: true)), (43, optShift, .sendStep(forward: false)),
            ]
        // ⌃⇧ join, the only free modifiers for hjkl without ⌘
        let join: [(UInt32, UInt32, Command)] = vim.map { ($0.0, 0x1200, .join($0.1)) }
        let fullScreen: [(UInt32, UInt32, Command)] = [(3, optShift, .toggleFullScreen)]
        let pop: [(UInt32, UInt32, Command)] = [(31, optShift, .popOut), (34, optShift, .popIn)]
        // In parts: as one expression it's more than the type checker will take
        return keymap + layout + later + sizing + join + fullScreen + pop
    }()

    @Test func defaultKeymapMatchesHardcodedKeymap() throws {
        let resolved = try Settings.default.bindings.map { try $0.binding.get() }
        #expect(resolved.count == Self.hardcoded.count)
        for (code, modifiers, command) in Self.hardcoded {
            #expect(resolved.contains { $0.0.keyCode == code && $0.0.carbonModifiers == modifiers && $0.1 == command },
                    "missing \(code)/\(modifiers) → \(command.text)")
        }
    }

    @Test func defaultRulesMatchHardcodedRules() {
        let settings = Settings.default
        #expect(settings.floatRules.apps == FloatRules.default.apps)
        #expect(settings.spaceRules.labels == SpaceRules.default.labels)
        #expect(settings.spaceRules.layouts == SpaceRules.default.layouts)
        #expect(settings.spaceRules.apps == SpaceRules.default.apps)
    }

    @Test func everyDefaultCommandRoundTripsThroughText() throws {
        for (_, binding) in Settings.default.bindings {
            let command = try binding.get().1
            #expect(Command(command.text) == command)
        }
    }

    @Test func olderConfigsWithoutFollowSettingsKeepTodaysBehaviour() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(Settings.default))
        #expect(decoded.followAfterSending == nil)
        #expect(decoded.followsSends)
        #expect(!decoded.followsRouting)
    }

    @Test func shortcutsStayOnUnlessTurnedOff() throws {
        #expect(Settings.default.usesShortcuts)
        var settings = Settings.default
        settings.shortcuts = false
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.usesShortcuts)
        #expect(decoded.keys == Settings.default.keys)
    }

    @Test func menuBarItemsMissingFromTheFileAreAddedHidden() throws {
        let json = #"{"items": [{"item": "name", "shown": true}, {"item": "index", "shown": true}], "indexStyle": "stepper"}"#
        let menuBar = try JSONDecoder().decode(MenuBarSettings.self, from: Data(json.utf8))
        #expect(menuBar.orderedItems.map(\.item) == [.name, .index, .logo, .layout, .windowCount, .stacked, .profileIcon, .profileName])
        #expect(menuBar.orderedItems.filter(\.shown).map(\.item) == [.name, .index])
    }

    @Test func defaultsRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(Settings.default)
        #expect(try JSONDecoder().decode(Settings.self, from: data) == .default)
    }
}

@Suite struct SpacingLimits {
    /// Values typed into config.json beyond what Settings offers are pulled in, not laid out as written.
    @Test func outOfRangeValuesAreClamped() {
        var settings = Settings.default
        settings.gap = 5000
        settings.padding = -50
        settings.ratio = 5
        let spacing = settings.spacing(forDisplayWidth: 1512)
        #expect(spacing.gap == 200)
        #expect(spacing.padding == 0)
        #expect(spacing.ratio == BSPTree.ratioRange.upperBound)
    }
}

@Suite struct Chords {
    @Test(arguments: [
        ("alt-h", "h", [KeyChord.Modifier.alt]),
        ("opt-shift-1", "1", [.alt, .shift]),
        ("alt--", "-", [.alt]),
        ("cmd-ctrl-left", "left", [.cmd, .ctrl]),
    ])
    func parses(text: String, key: String, modifiers: [KeyChord.Modifier]) {
        #expect(KeyChord(text) == KeyChord(key: key, modifiers: Set(modifiers)))
    }

    @Test(arguments: ["alt-", "hyper-h", "alt-nope", ""])
    func rejects(text: String) {
        #expect(KeyChord(text) == nil)
    }

    @Test func textIsCanonicalOrder() {
        #expect(KeyChord("shift-alt-1")?.text == "alt-shift-1")
    }

    @Test func badBindingsReportWhy() {
        var settings = Settings.default
        settings.keys = ["alt-h": "focus up", "hyper-h": "zoom"]
        let errors = settings.bindings.compactMap { if case .failure(let e) = $0.binding { e } else { nil } }
        #expect(Set(errors.map { "\($0)" }) == ["badChord", "badCommand(\"focus up\")"])
    }
}

@Suite struct ReservedChords {
    @Test(arguments: ["ctrl-left", "ctrl-right", "ctrl-up", "cmd-q", "cmd-tab", "cmd-space"])
    func systemChordsAreReserved(_ text: String) { #expect(KeyChord(text)?.reservedReason != nil) }

    @Test(arguments: ["alt-left", "ctrl-alt-left", "cmd-shift-q", "alt-f"])
    func othersAreFree(_ text: String) { #expect(KeyChord(text)?.reservedReason == nil) }
}

@Suite struct TitleRuleChecks {
    let windows: [(app: String, title: String)] = [("Finder", "Copy"), ("Finder", "Documents"), ("Finder", "Get Info"), ("Safari", "Copy")]

    @Test func acceptsARegex() { #expect(Settings.TitleRule.problem(with: "Co(py|nnect)|Info") == nil) }
    @Test func rejectsAnUnbalancedOne() { #expect(Settings.TitleRule.problem(with: "Co(py") != nil) }
    @Test func rejectsEmpty() { #expect(Settings.TitleRule.problem(with: "") != nil) }
    @Test func countsOnlyThatAppsMatches() {
        #expect(Settings.TitleRule(app: "Finder", title: "Copy|Info").matches(in: windows) == 2)
    }
}
