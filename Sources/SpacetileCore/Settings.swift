import CoreGraphics
import Foundation

/// Everything in `~/.config/spacetile/config.json`. Hotkeys, rules and mouse options apply as soon
/// as the file changes; Space layout modes only affect Spaces laid out after the change. The tiling
/// and stacking algorithms apply to every Space at once.
public struct Settings: Codable, Equatable, Sendable {
    /// Key chord → command, e.g. `"alt-shift-h": "swap west"`.
    public var keys: [String: String]
    /// Register `keys` as global shortcuts. Off releases every chord, for people who bind the
    /// commands in another tool such as Raycast; `keys` is kept. Default on.
    public var shortcuts: Bool?
    public var focusFollowsMouse: Bool
    public var mouseFollowsFocus: Bool
    /// Switch to the destination Space after sending a window there by key or edge drag. Default on.
    public var followAfterSending: Bool?
    /// Switch to the Space an app rule sends a new window to. Default off.
    public var followRoutedWindows: Bool?
    /// Draw windows' content in the mini-map and profile editor, which needs Screen Recording.
    /// Default off.
    public var windowPreviews: Bool?
    /// What the menu-bar item shows; nil means `MenuBarSettings.default`.
    public var menuBar: MenuBarSettings?
    /// Apps whose windows always float.
    public var floatApps: [String]
    public var floatTitles: [TitleRule]
    public var spaces: [SpaceSettings]
    /// Fixed spacing in points, or nil for the automatic display-width rule.
    public var padding: Double?
    public var gap: Double?
    /// Padding round each display's edge and gaps between tiles. Off tiles edge to edge and keeps
    /// `padding` and `gap` for turning it back on. Default on.
    public var spacing: Bool?
    /// Outline the focused window in the accent colour. Default off.
    public var activeBorder: Bool?
    /// The outline's colour as `"#RRGGBB"`; nil means the accent colour.
    public var borderColor: String?
    /// The outline's opacity; nil means fully opaque.
    public var borderOpacity: Double?
    /// Shade the windows and desktop behind the focused window, on its display. Default off.
    public var dimInactive: Bool?
    /// The shade's opacity; nil means 0.3.
    public var dimOpacity: Double?
    /// Slide and resize windows into their tiles instead of jumping, unless Reduce Motion is on.
    /// Default off, since Accessibility moves are slow enough that it can make tiling feel laggy.
    public var animateWindows: Bool?
    /// The share an existing window keeps when a new window splits its tile, and the main window's
    /// share with master and stack tiling; nil means a half.
    public var ratio: Double?
    /// How Tile mode places windows on every Space; nil means BSP.
    public var tiling: TileAlgorithm?
    /// How Stack mode lays windows out on every Space; nil means fill.
    public var stacking: StackAlgorithm?
    /// App name → Space number for windows created while Spacetile runs.
    public var appSpaces: [String: Int]
    /// Apps whose new windows go native full screen, after any `appSpaces` rule has moved them, so
    /// the full-screen Space lands after that Desktop.
    public var fullScreenApps: [String]?
    /// Read macOS's own tiling (the green button's Move & Resize and Fill & Arrange, the Window menu,
    /// fn⌃ arrows) as Spacetile commands on tiled windows, instead of undoing it. Default on.
    public var nativeTiling: Bool?

    public struct TitleRule: Codable, Equatable, Sendable {
        public var app: String
        /// A regular expression; a window whose title contains a match floats.
        public var title: String

        public init(app: String, title: String) {
            self.app = app
            self.title = title
        }
    }

    public struct SpaceSettings: Codable, Equatable, Sendable {
        public var space: Int
        public var label: String?
        public var layout: LayoutMode?

        public init(space: Int, label: String?, layout: LayoutMode?) {
            self.space = space
            self.label = label
            self.layout = layout
        }
    }

    public var followsSends: Bool { followAfterSending ?? true }
    public var usesShortcuts: Bool { shortcuts ?? true }
    public var menuBarSettings: MenuBarSettings { menuBar ?? .default }
    public var followsRouting: Bool { followRoutedWindows ?? false }
    public var showsWindowPreviews: Bool { windowPreviews ?? false }
    public var adoptsNativeTiling: Bool { nativeTiling ?? true }
    public var usesSpacing: Bool { spacing ?? true }
    public var showsActiveBorder: Bool { activeBorder ?? false }
    public var dimsInactive: Bool { dimInactive ?? false }
    public var activeBorderOpacity: Double { (borderOpacity ?? 1).clamped(to: Self.borderOpacityRange) }
    public var inactiveDimOpacity: Double { (dimOpacity ?? 0.3).clamped(to: Self.dimOpacityRange) }
    public var animatesWindows: Bool { animateWindows ?? false }
    public var fullScreenRules: Set<String> { Set(fullScreenApps ?? []) }
    public var tileAlgorithm: TileAlgorithm { tiling ?? .bsp }
    public var stackAlgorithm: StackAlgorithm { stacking ?? .fill }
    /// `ratio` within the range a split can take, or a half.
    public var splitRatio: Double { (ratio ?? 0.5).clamped(to: BSPTree.ratioRange) }

    /// The padding and gap Settings offers; values edited into config.json beyond it are pulled in.
    public static let spacingRange = 0.0...200.0
    /// The opacities Settings offers; a border or shade fainter than these is hard to see at all.
    public static let borderOpacityRange = 0.1...1.0
    public static let dimOpacityRange = 0.05...0.9

    public func spacing(forDisplayWidth width: CGFloat) -> Spacing {
        var spacing = Spacing.forDisplay(width: width)
        padding.map { spacing.padding = CGFloat($0.clamped(to: Self.spacingRange)) }
        gap.map { spacing.gap = CGFloat($0.clamped(to: Self.spacingRange)) }
        if !usesSpacing { (spacing.padding, spacing.gap) = (0, 0) }
        spacing.ratio = splitRatio
        return spacing
    }

    /// Flips the on-off setting `toggle` names.
    public mutating func flip(_ toggle: SettingToggle) {
        switch toggle {
        case .spacing: spacing = !usesSpacing
        case .border: activeBorder = !showsActiveBorder
        case .dim: dimInactive = !dimsInactive
        }
    }

    public var floatRules: FloatRules {
        FloatRules(apps: Set(floatApps), titles: floatTitles.map { ($0.app, $0.title) })
    }

    public var spaceRules: SpaceRules {
        SpaceRules(labels: Dictionary(spaces.compactMap { d in d.label.map { (d.space, $0) } }, uniquingKeysWith: { a, _ in a }),
                   layouts: Dictionary(spaces.compactMap { d in d.layout.map { (d.space, $0) } }, uniquingKeysWith: { a, _ in a }),
                   apps: appSpaces)
    }

    /// Every binding resolved to a key code and modifiers, or the reason it couldn't be.
    public var bindings: [(chord: String, binding: Result<(KeyChord, Command), BindingError>)] {
        keys.sorted { $0.key < $1.key }.map { chord, text in
            guard let parsed = KeyChord(chord) else { return (chord, .failure(.badChord)) }
            guard let command = Command(text) else { return (chord, .failure(.badCommand(text))) }
            return (chord, .success((parsed, command)))
        }
    }

    public enum BindingError: Error, Equatable, Sendable {
        case badChord
        case badCommand(String)
    }

    /// yabai-style ⌥ hjkl and number chords plus Spacetile's own: ⌥n/⌥p stacks, ⌥⇧⌃hjkl preselect, ⌥e split toggle, ⌥. ⌥, ⌥` Spaces, ⌥⇧. ⌥⇧, sending,
    /// and the ⌥⌃ sizing family (place, corners, centre, grow, shrink, restore).
    public static let `default`: Settings = {
        var keys: [String: String] = [:]
        for number in 1...10 {
            let key = String(number % 10)
            keys["alt-\(key)"] = "space \(number)"
            keys["alt-shift-\(key)"] = "send \(number)"
        }
        for (key, direction) in [("h", "west"), ("j", "south"), ("k", "north"), ("l", "east")] {
            keys["alt-\(key)"] = "focus \(direction)"
            keys["alt-shift-\(key)"] = "swap \(direction)"
            // Every ⌥ family already has hjkl, and ⌘ chords clash with apps (⌘H hides)
            keys["ctrl-shift-\(key)"] = "join \(direction)"
        }
        keys.merge([
            "ctrl-alt-h": "place left", "ctrl-alt-j": "place bottom", "ctrl-alt-k": "place top", "ctrl-alt-l": "place right",
            "ctrl-alt-y": "place top-left", "ctrl-alt-u": "place top-right",
            "ctrl-alt-b": "place bottom-left", "ctrl-alt-n": "place bottom-right",
            "ctrl-alt-c": "place center", "ctrl-alt-up": "place column",
            "ctrl-alt-=": "grow", "ctrl-alt--": "shrink", "ctrl-alt-r": "restore",
            "alt-shift-.": "send next", "alt-shift-,": "send prev",
            "alt-z": "zoom", "alt-m": "zoom", "alt-f": "float",
            "alt-s": "layout stack", "alt-d": "layout bsp",
            "alt-b": "balance", "alt-=": "balance", "alt-]": "balance",
            "alt-x": "mirror vertical", "alt-y": "mirror horizontal", "alt-r": "rotate 270",
            "alt-n": "stack next", "alt-p": "stack prev",
            "ctrl-alt-shift-h": "preselect west", "ctrl-alt-shift-j": "preselect south",
            "ctrl-alt-shift-k": "preselect north", "ctrl-alt-shift-l": "preselect east",
            "alt-e": "split", "alt-.": "space next", "alt-,": "space prev", "alt-`": "space last",
            "alt-shift-f": "fullscreen", "alt-shift-o": "pop out", "alt-shift-i": "pop in",
        ]) { a, _ in a }
        let rules = SpaceRules.default
        return Settings(
            keys: keys, focusFollowsMouse: true, mouseFollowsFocus: true,
            floatApps: FloatRules.default.apps.sorted(),
            floatTitles: FloatRules.default.titles.map { TitleRule(app: $0.app, title: $0.pattern) },
            spaces: (1...10).map { SpaceSettings(space: $0, label: rules.labels[$0], layout: rules.layouts[$0]) },
            appSpaces: rules.apps
        )
    }()
}

/// A key plus modifiers, written `"ctrl-alt-shift-cmd-key"` (modifiers in any order).
/// Keys are named by their US-layout character and identified by physical position (key code).
public struct KeyChord: Hashable, Sendable {
    public var key: String
    public var modifiers: Set<Modifier>

    public enum Modifier: String, CaseIterable, Sendable {
        case ctrl, alt, shift, cmd

        /// Carbon modifier flag values (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
        public var carbonFlag: UInt32 {
            switch self {
            case .ctrl: 0x1000
            case .alt: 0x0800
            case .shift: 0x0200
            case .cmd: 0x0100
            }
        }
    }

    public init(key: String, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public init?(_ text: String) {
        // "-" can be a key itself ("alt--"), so split from the right
        var parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("--") { parts = Array(parts.dropLast(2)) + ["-"] }
        guard let key = parts.last, Self.keyCodes[key] != nil else { return nil }
        let modifiers = parts.dropLast().compactMap { Modifier(rawValue: $0 == "opt" ? "alt" : $0) }
        guard modifiers.count == parts.count - 1 else { return nil }
        self.init(key: key, modifiers: Set(modifiers))
    }

    public init?(keyCode: UInt32, modifiers: Set<Modifier>) {
        guard let key = Self.keyCodes.first(where: { $0.value == keyCode })?.key else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    public var text: String {
        (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "-")
    }

    public var keyCode: UInt32 { Self.keyCodes[key]! }
    public var carbonModifiers: UInt32 { modifiers.reduce(0) { $0 | $1.carbonFlag } }

    /// ANSI key codes. The digit row isn't in order: 5 is 23 and 6 is 22; 7, 8, 9 are 26, 28, 25.
    public static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}

extension KeyChord {
    /// Why Spacetile won't bind this chord, or nil. These belong to macOS, and ⌃← and ⌃→ are also how
    /// Spacetile steps between Spaces when instant switching fails.
    public var reservedReason: String? {
        switch (modifiers, key) {
        case ([.ctrl], "left"), ([.ctrl], "right"):
            "⌃← and ⌃→ move between Spaces in macOS, and Spacetile uses them itself when instant switching fails."
        case ([.ctrl], "up"), ([.ctrl], "down"): "⌃↑ and ⌃↓ open Mission Control and App Exposé."
        case ([.cmd], "q"): "⌘Q quits the app in front."
        case ([.cmd], "tab"): "⌘Tab switches between apps."
        case ([.cmd], "space"): "⌘Space opens Spotlight."
        default: nil
        }
    }
}
