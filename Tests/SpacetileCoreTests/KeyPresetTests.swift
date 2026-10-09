import Testing
@testable import SpacetileCore

@Suite struct KeyPresets {
    @Test(arguments: KeyPreset.all.map(\.id))
    func everyShortcutAndCommandIsReal(id: String) throws {
        let preset = try #require(KeyPreset.all.first { $0.id == id })
        for (chord, command) in preset.keys {
            let parsed = try #require(KeyChord(chord), "\(chord) in \(preset.name)")
            #expect(parsed.reservedReason == nil, "\(chord) in \(preset.name) belongs to macOS")
            #expect(Command(command) != nil, "\(command) in \(preset.name)")
        }
    }

    @Test func theToolsShortcutsWinAndSpacetilesStayElsewhere() {
        let keys = KeyPreset.rectangle.settingsKeys
        #expect(keys["ctrl-alt-j"] == "place bottom-left")
        // Spacetile's ⌥ families don't clash with Rectangle's ⌃⌥ ones, so they stay
        #expect(keys["alt-h"] == "focus west")
        // Restore moves to ⌫, freeing Spacetile's ⌃⌥R
        #expect(keys["ctrl-alt-r"] == nil)
    }

    @Test(arguments: KeyPreset.all.map(\.id))
    func noSpacetileCommandIsLeftWithoutAShortcut(id: String) throws {
        let preset = try #require(KeyPreset.all.first { $0.id == id })
        #expect(preset.displaced.isEmpty, "\(preset.name) leaves \(preset.displaced) unbound")
        for (chord, command) in preset.fallbacks {
            #expect(KeyChord(chord).map { $0.reservedReason == nil } == true, "\(chord) in \(preset.name)")
            #expect(preset.settingsKeys[chord] == command, "\(chord) in \(preset.name) is already taken")
        }
    }

    @Test func displacedCommandsMoveToTheirFallback() {
        // ⌃⌥J and ⌃⌥K were place bottom and place top; Rectangle uses them for quarters
        #expect(KeyPreset.rectangle.settingsKeys["ctrl-alt-cmd-up"] == "place top")
        #expect(KeyPreset.rectangle.settingsKeys["ctrl-alt-shift-up"] == "place column")
    }
}
