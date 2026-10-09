/// Another window manager's default shortcuts, mapped onto Spacetile's commands, for people moving
/// over. Where Spacetile has no counterpart, the tool's action is listed in `unmatched` instead.
public struct KeyPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// One line on where the shortcuts come from.
    public let note: String
    /// Chord → Spacetile command, as `config.json` writes them.
    public let keys: [String: String]
    /// The tool's default actions Spacetile can't do, by the tool's own name for them.
    public let unmatched: [String]
    /// New homes, in the tool's own style, for Spacetile commands whose default chords the tool uses.
    public let fallbacks: [String: String]

    init(id: String, name: String, note: String, keys: [String: String], unmatched: [String], fallbacks: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.note = note
        self.keys = keys
        self.unmatched = unmatched
        self.fallbacks = fallbacks
    }

    /// Spacetile's defaults with this tool's shortcuts laid over them. A default gives way when the
    /// tool uses its chord or binds its command; one that loses its only chord moves to its fallback.
    public var settingsKeys: [String: String] {
        let taken = Set(keys.keys), bound = Set(keys.values)
        var merged = Settings.default.keys.filter { !taken.contains($0.key) && !bound.contains($0.value) }
            .merging(keys) { _, preset in preset }
        let reachable = Set(merged.values)
        for (chord, command) in fallbacks where merged[chord] == nil && !reachable.contains(command) { merged[chord] = command }
        return merged
    }

    /// Spacetile's commands this tool has no default shortcut for. Most keep Spacetile's own;
    /// `displaced` ones lose theirs to the tool's.
    public var spacetileOnly: [String] {
        Set(Settings.default.keys.values).subtracting(keys.values).sorted()
    }

    /// Spacetile commands left without a shortcut, because the tool uses their default chords for
    /// something else.
    public var displaced: [String] {
        Set(Settings.default.keys.values).subtracting(settingsKeys.values).sorted()
    }
}

// Each tool's out-of-the-box shortcuts, from its own default config or docs (October 2026).
// Tools that ship none (Raycast, Moom, yabai) have no preset; Raycast's own presets copy
// Rectangle, Spectacle and Magnet.
extension KeyPreset {
    public static let all: [KeyPreset] = [rectangle, spectacle, aerospace, amethyst, betterStage, shiftPlus]

    /// Rectangle's Recommended set, which Magnet's and Raycast's Rectangle preset match.
    static let rectangle = KeyPreset(
        id: "rectangle", name: "Rectangle",
        note: "Rectangle's Recommended set: ⌃⌥ with arrows for halves, U I J K for quarters, D F G and E T for thirds.",
        keys: [
            "ctrl-alt-left": "place left 1/2", "ctrl-alt-right": "place right 1/2",
            "ctrl-alt-up": "place top 1/2", "ctrl-alt-down": "place bottom 1/2",
            "ctrl-alt-u": "place top-left", "ctrl-alt-i": "place top-right",
            "ctrl-alt-j": "place bottom-left", "ctrl-alt-k": "place bottom-right",
            "ctrl-alt-return": "zoom", "ctrl-alt-c": "place center",
            "ctrl-alt-=": "grow", "ctrl-alt--": "shrink", "ctrl-alt-delete": "restore",
            "ctrl-alt-cmd-left": "send display prev", "ctrl-alt-cmd-right": "send display next",
            "ctrl-alt-d": "place left 1/3", "ctrl-alt-f": "place center", "ctrl-alt-g": "place right 1/3",
            "ctrl-alt-e": "place left 2/3", "ctrl-alt-t": "place right 2/3",
            "ctrl-alt-shift-up": "place column",
        ],
        unmatched: ["Center Two Thirds", "Center keeping the window's size"],
        // ⌃⌥J and ⌃⌥K go to quarters; Spacetile's cycling top and bottom join ⌃⌥⌘, beside the display moves
        fallbacks: ["ctrl-alt-cmd-up": "place top", "ctrl-alt-cmd-down": "place bottom"])

    /// Spectacle's defaults, also Rectangle's alternative set: repeating a half cycles its size.
    static let spectacle = KeyPreset(
        id: "spectacle", name: "Spectacle",
        note: "Spectacle's defaults, also Rectangle's Spectacle set: ⌥⌘ with arrows for halves that cycle ½ → ⅔ → ⅓.",
        keys: [
            "alt-cmd-left": "place left", "alt-cmd-right": "place right",
            "alt-cmd-up": "place top", "alt-cmd-down": "place bottom",
            "ctrl-cmd-left": "place top-left", "ctrl-cmd-right": "place top-right",
            "ctrl-shift-cmd-left": "place bottom-left", "ctrl-shift-cmd-right": "place bottom-right",
            "alt-cmd-f": "zoom", "alt-cmd-c": "place center",
            "ctrl-alt-shift-right": "grow", "ctrl-alt-shift-left": "shrink", "ctrl-alt-delete": "restore",
            "ctrl-alt-cmd-left": "send display prev", "ctrl-alt-cmd-right": "send display next",
            "ctrl-alt-shift-up": "place column",
        ],
        unmatched: ["Undo and Redo", "Center keeping the window's size"])

    static let aerospace = KeyPreset(
        id: "aerospace", name: "AeroSpace",
        note: "AeroSpace's default config: ⌥ HJKL to focus, ⌥⇧ HJKL to move, ⌥1–9 for workspaces, ⌥Tab for the last one.",
        keys: [
            "alt-h": "focus west", "alt-j": "focus south", "alt-k": "focus north", "alt-l": "focus east",
            "alt-shift-h": "swap west", "alt-shift-j": "swap south", "alt-shift-k": "swap north", "alt-shift-l": "swap east",
            "alt-/": "layout bsp", "alt-,": "layout stack",
            "alt--": "shrink", "alt-=": "grow",
            "alt-tab": "space last",
        ].merging((1...9).flatMap { [("alt-\($0)", "space \($0)"), ("alt-shift-\($0)", "send \($0)")] }) { a, _ in a },
        unmatched: ["Workspaces A–Z", "Move workspace to another monitor", "Service mode (join, float and flatten have direct shortcuts here)",
                    "Toggling tile orientation with ⌥/ (⌥E splits the other way here)"],
        // ⌥, goes to the accordion (stack) layout; ⌥[ is how AeroSpace configs usually step back
        fallbacks: ["alt-[": "space prev"])

    /// mod1 is ⌥⇧ and mod2 ⌃⌥⇧.
    static let amethyst = KeyPreset(
        id: "amethyst", name: "Amethyst",
        note: "Amethyst's defaults, with mod1 as ⌥⇧ and mod2 as ⌃⌥⇧.",
        keys: [
            "alt-shift-d": "layout stack", "alt-shift-h": "shrink", "alt-shift-l": "grow",
            "alt-shift-p": "display prev", "alt-shift-n": "display next",
            "ctrl-alt-shift-h": "send display prev", "ctrl-alt-shift-l": "send display next",
            "ctrl-alt-shift-left": "send prev", "ctrl-alt-shift-right": "send next",
            "alt-shift-t": "float", "ctrl-alt-shift-t": "pause", "alt-shift-z": "retile",
            "ctrl-alt-shift-0": "send 10", "alt-shift-return": "pop out",
        ].merging((1...9).map { ("ctrl-alt-shift-\($0)", "send \($0)") }) { a, _ in a },
        unmatched: ["Cycling layouts", "Tall, wide and column layouts", "Main pane count", "Focus and swap round the layout (ccw, cw)",
                    "Focus main", "Focus or throw to screen 1–5", "Show current layout", "Relaunch",
                    "Toggling focus follows mouse"],
        // ⌥⇧H/L resize and ⌃⌥⇧H/L throw to a screen: swap takes mod1 arrows, preselect mod2 ‹ ›
        fallbacks: ["alt-shift-left": "swap west", "alt-shift-right": "swap east",
                    "ctrl-alt-shift-,": "preselect west", "ctrl-alt-shift-.": "preselect east"])

    /// BetterStage's Standard set.
    static let betterStage = KeyPreset(
        id: "betterstage", name: "BetterStage",
        note: "BetterStage's Standard set: ⌥1–9 for stages, ⌥⌘ IJKL to focus, ⌃⌥ for halves, quarters and thirds.",
        keys: [
            "alt-down": "retile", "alt-left": "space prev", "alt-right": "space next",
            "alt-tab": "space next", "alt-shift-tab": "space prev",
            "alt-cmd-j": "focus west", "alt-cmd-k": "focus south", "alt-cmd-i": "focus north", "alt-cmd-l": "focus east",
            "ctrl-alt-left": "place left 1/2", "ctrl-alt-right": "place right 1/2",
            "ctrl-alt-up": "place top 1/2", "ctrl-alt-down": "place bottom 1/2",
            "ctrl-alt-c": "place center", "ctrl-alt-return": "zoom",
            "ctrl-alt-u": "place top-left", "ctrl-alt-i": "place top-right",
            "ctrl-alt-j": "place bottom-left", "ctrl-alt-k": "place bottom-right",
            "ctrl-alt-a": "place left 1/3", "ctrl-alt-s": "place center", "ctrl-alt-d": "place right 1/3",
            "ctrl-alt-q": "place left 2/3", "ctrl-alt-w": "place right 2/3",
        ].merging((1...9).flatMap { [("alt-\($0)", "space \($0)"), ("alt-shift-\($0)", "send \($0)")] }) { a, _ in a },
        unmatched: ["Stages Bar", "New and close stage (macOS adds and removes Spaces in Mission Control)",
                    "Cycle window mode", "Center two-thirds"],
        // As Rectangle: ⌃⌥J and ⌃⌥K go to quarters, and ⌃⌥↑ to the top half
        fallbacks: ["ctrl-alt-cmd-up": "place top", "ctrl-alt-cmd-down": "place bottom", "ctrl-alt-shift-up": "place column"])

    static let shiftPlus = KeyPreset(
        id: "shiftplus", name: "ShiftPlus",
        note: "ShiftPlus's two default shortcuts: ⌘; for the previous workspace and ⌃⌘→ to cycle.",
        keys: ["cmd-;": "space last", "ctrl-cmd-right": "space next"],
        unmatched: ["Capturing a workspace by shortcut (Save Layout as Profile… in the menu bar)"])
}
