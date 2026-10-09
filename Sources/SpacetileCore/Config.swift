import CoreGraphics
import Foundation

/// Everything a keybinding can ask the window manager to do.
public enum Command: Equatable, Sendable {
    case focus(Direction)
    case swap(Direction)
    /// Moves the focused tile's border along `axis` by `points` (negative is west/north).
    case moveBorder(Axis, CGFloat)
    case toggleZoom
    case toggleFloat
    case setLayout(LayoutMode)
    case balance
    case mirror(Axis)
    case rotate(Rotation)
    case retile
    /// Desktops are numbered from 1 in Mission Control order.
    case focusSpace(Int)
    /// Sends the focused window to a Space and follows it.
    case sendToSpace(Int)
    case cycleStack(forward: Bool)
    /// Closes the focused window through its close button.
    case close
    /// Saves the current arrangement of every Space as a named profile.
    case capture(String)
    /// Restores a saved profile.
    case load(String)
    /// Sets where the next window goes; the same direction again cancels.
    case preselect(Direction)
    /// Exchanges the focused window with the main tile's (master and stack) or the largest tile's
    /// front window, remembering the pair for `popIn`. On the popped window it pops in instead.
    case popOut
    /// Exchanges the last popped pair back.
    case popIn
    /// Moves the focused window past its neighbour, into the neighbour's part of the tree.
    case join(Direction)
    /// Flips the focused window's split between side by side and stacked.
    case toggleSplit
    /// Steps to the next or previous Space, wrapping round.
    case stepSpace(forward: Bool)
    /// Returns to the Space visited before the current one.
    case lastSpace
    /// Gives the focused window a region of the Space; the others re-tile around it.
    case place(Region)
    /// Moves the focused window's inner borders outwards (true) or inwards by a tenth of the Space.
    case resize(grow: Bool)
    /// Undoes the last place, grow or shrink on this Space.
    case restore
    /// Sends the focused window to the next or previous Space, wrapping round, and follows it.
    case sendStep(forward: Bool)
    /// Stops or restarts all tiling. While paused Spacetile moves no windows and releases every
    /// shortcut except the ones bound to `pause`.
    case togglePause
    /// Opens the Settings window, for when the menu-bar item is hidden.
    case openSettings
    /// Focuses the display to the right (or left), wrapping round, and makes it the active one.
    case focusDisplay(forward: Bool)
    /// Moves the focused window to the Space showing on the display to the right (or left).
    case sendToDisplay(forward: Bool)
    /// Turns native full screen on or off for the focused window. A tiled window keeps its tile.
    case toggleFullScreen
    /// The focused window and its neighbour in the tiling go full screen together, side by side
    /// (macOS Split View), the focused one on the side it's on now.
    case fullScreenPair
    /// Steps to the next or previous full-screen app's Space on the active display, wrapping round.
    case stepFullScreen(forward: Bool)
    /// Turns a display setting on or off and saves it to config.json.
    case toggle(SettingToggle)
}

/// The on-off settings a command can flip.
public enum SettingToggle: String, CaseIterable, Sendable {
    /// Padding and gaps.
    case spacing
    /// The focused window's outline.
    case border
    /// The shade behind the focused window.
    case dim
}

/// Per-Space labels, layouts and app → Space rules.
public struct SpaceRules: Sendable {
    public var labels: [Int: String]
    public var layouts: [Int: LayoutMode]
    /// App name → Space number. Applies to windows created while Spacetile runs.
    public var apps: [String: Int]

    public func layout(forSpace number: Int?) -> LayoutMode { number.flatMap { layouts[$0] } ?? .bsp }

    /// None: every Desktop starts unlabelled in BSP, and new windows open where you are.
    public static let `default` = SpaceRules(labels: [:], layouts: [:], apps: [:])
}

/// Padding and gaps that depend on the display's width, plus the default
/// split ratio: the share an existing window keeps when a new one splits its tile.
public struct Spacing: Equatable, Sendable {
    public var padding: CGFloat
    public var gap: CGFloat
    public var ratio: Double

    public static func forDisplay(width: CGFloat) -> Spacing {
        width > 1600
            ? Spacing(padding: 10, gap: 10, ratio: 0.5)
            : Spacing(padding: 5, gap: 5, ratio: 0.5)
    }
}

/// Decides which windows float instead of tiling.
public struct FloatRules: Sendable {
    public var apps: Set<String>
    /// App name → title pattern; a window whose title contains a match floats (yabai regex semantics).
    public var titles: [(app: String, pattern: String)]

    public func floats(app: String, title: String) -> Bool {
        apps.contains(app) || titles.contains { $0.app == app && title.range(of: $0.pattern, options: .regularExpression) != nil }
    }

    /// macOS's own utilities and Finder's dialogs: small windows that don't suit a tile.
    public static let `default` = FloatRules(
        apps: [
            "Activity Monitor", "App Store", "Archive Utility", "Calculator", "Dictionary", "FaceTime",
            "Photo Booth", "Screen Sharing", "Software Update", "System Information", "System Settings",
        ],
        titles: [
            ("Finder", "Co(py|nnect)|Move|Info|Pref"),
        ]
    )
}

extension Command {
    /// The text form `Command(_:)` parses, e.g. `"border horizontal -100"`.
    public var text: String {
        func name(_ d: Direction) -> String { "\(d)" }
        switch self {
        case .focus(let d): return "focus \(name(d))"
        case .swap(let d): return "swap \(name(d))"
        case let .moveBorder(axis, points): return "border \(axis.rawValue) \(Int(points))"
        case .toggleZoom: return "zoom"
        case .toggleFloat: return "float"
        case .setLayout(let mode): return "layout \(mode.rawValue)"
        case .balance: return "balance"
        case .mirror(let axis): return "mirror \(axis.rawValue)"
        case .rotate(let r): return "rotate \(r == .quarter ? 90 : r == .half ? 180 : 270)"
        case .retile: return "retile"
        case .focusSpace(let n): return "space \(n)"
        case .sendToSpace(let n): return "send \(n)"
        case .cycleStack(let forward): return "stack \(forward ? "next" : "prev")"
        case .close: return "close"
        case .capture(let name): return "capture \(name)"
        case .load(let name): return "load \(name)"
        case .preselect(let d): return "preselect \(name(d))"
        case .join(let d): return "join \(name(d))"
        case .popOut: return "pop out"
        case .popIn: return "pop in"
        case .toggleSplit: return "split"
        case .stepSpace(let forward): return "space \(forward ? "next" : "prev")"
        case .lastSpace: return "space last"
        case .place(let region): return "place \(region.text)"
        case .resize(let grow): return grow ? "grow" : "shrink"
        case .restore: return "restore"
        case .sendStep(let forward): return "send \(forward ? "next" : "prev")"
        case .togglePause: return "pause"
        case .openSettings: return "settings"
        case .focusDisplay(let forward): return "display \(forward ? "next" : "prev")"
        case .sendToDisplay(let forward): return "send display \(forward ? "next" : "prev")"
        case .toggleFullScreen: return "fullscreen"
        case .fullScreenPair: return "fullscreen pair"
        case .stepFullScreen(let forward): return "space fullscreen \(forward ? "next" : "prev")"
        case .toggle(let setting): return "toggle \(setting.rawValue)"
        }
    }

    /// Parses the text form used by `spacetile-ctl`, e.g. `focus west`, `border horizontal -100`, `space 3`, `stack next`.
    public init?(_ text: String) {
        let words = text.split(separator: " ").map(String.init)
        let directions: [String: Direction] = ["west": .west, "east": .east, "north": .north, "south": .south]
        let axes: [String: Axis] = ["horizontal": .horizontal, "vertical": .vertical]
        let modes: [String: LayoutMode] = ["bsp": .bsp, "stack": .stack, "float": .float]
        let rotations: [String: Rotation] = ["90": .quarter, "180": .half, "270": .threeQuarter]
        switch (words.first, words.dropFirst().first) {
        case let ("focus", d?): guard let d = directions[d] else { return nil }; self = .focus(d)
        case let ("swap", d?): guard let d = directions[d] else { return nil }; self = .swap(d)
        case let ("border", a?):
            guard let a = axes[a], let points = words.dropFirst(2).first.flatMap(Double.init) else { return nil }
            self = .moveBorder(a, CGFloat(points))
        case let ("layout", m?): guard let m = modes[m] else { return nil }; self = .setLayout(m)
        case let ("mirror", a?): guard let a = axes[a] else { return nil }; self = .mirror(a)
        case let ("rotate", r?): guard let r = rotations[r] else { return nil }; self = .rotate(r)
        case ("zoom", nil): self = .toggleZoom
        case ("float", nil): self = .toggleFloat
        case ("balance", nil): self = .balance
        case ("retile", nil): self = .retile
        case ("close", nil): self = .close
        case ("capture", _?): self = .capture(words.dropFirst().joined(separator: " "))
        case ("load", _?): self = .load(words.dropFirst().joined(separator: " "))
        case ("space", "next"): self = .stepSpace(forward: true)
        case ("space", "prev"): self = .stepSpace(forward: false)
        case ("space", "last"): self = .lastSpace
        case ("space", "fullscreen"):
            guard words.count == 3, words[2] == "next" || words[2] == "prev" else { return nil }
            self = .stepFullScreen(forward: words[2] == "next")
        case let ("space", n?): guard let n = Int(n) else { return nil }; self = .focusSpace(n)
        case let ("preselect", d?): guard let d = directions[d] else { return nil }; self = .preselect(d)
        case let ("join", d?): guard let d = directions[d] else { return nil }; self = .join(d)
        case ("split", nil): self = .toggleSplit
        case ("pop", "out"): self = .popOut
        case ("pop", "in"): self = .popIn
        case ("display", "next"): self = .focusDisplay(forward: true)
        case ("display", "prev"): self = .focusDisplay(forward: false)
        case ("send", "display"):
            guard words.count == 3, words[2] == "next" || words[2] == "prev" else { return nil }
            self = .sendToDisplay(forward: words[2] == "next")
        case ("send", "next"): self = .sendStep(forward: true)
        case ("send", "prev"): self = .sendStep(forward: false)
        case let ("send", n?): guard let n = Int(n) else { return nil }; self = .sendToSpace(n)
        case ("place", _?):
            guard let region = Region(words.dropFirst().joined(separator: " ")) else { return nil }
            self = .place(region)
        case ("grow", nil): self = .resize(grow: true)
        case ("shrink", nil): self = .resize(grow: false)
        case ("restore", nil): self = .restore
        case ("pause", nil): self = .togglePause
        case ("settings", nil): self = .openSettings
        case ("fullscreen", nil): self = .toggleFullScreen
        case ("fullscreen", "pair") where words.count == 2: self = .fullScreenPair
        case let ("toggle", name?):
            guard words.count == 2, let setting = SettingToggle(rawValue: name) else { return nil }
            self = .toggle(setting)
        case let ("stack", step?):
            guard step == "next" || step == "prev" else { return nil }
            self = .cycleStack(forward: step == "next")
        default: return nil
        }
    }
}

extension Region {
    private static let edges: [String: Direction] = ["left": .west, "right": .east, "top": .north, "bottom": .south]
    private static let columnNames = ["left", "center", "right"]
    private static let fractions: [(text: String, value: Double)] = [("1/4", 0.25), ("1/3", 1.0 / 3), ("1/2", 0.5), ("2/3", 2.0 / 3), ("3/4", 0.75)]

    /// `left`, `left 3/4`, `top-left`, `center`, `top-center-sixth`, `column`.
    public init?(_ text: String) {
        let words = text.split(separator: " ").map(String.init)
        guard let name = words.first, words.count <= 2 else { return nil }
        let parts = name.split(separator: "-").map(String.init)
        switch parts.count {
        case 1 where name == "center" && words.count == 1:
            self = .center
        case 1 where name == "column" && words.count == 1:
            self = .column(span: nil)
        case 1:
            guard let edge = Self.edges[name] else { return nil }
            let fraction = words.count == 2 ? Self.fraction(words[1]) : nil
            if words.count == 2, fraction == nil { return nil }
            self = .edge(edge, fraction: fraction)
        case 2 where words.count == 1:
            guard let vertical = Self.edges[parts[0]], vertical.axis == .vertical,
                  let horizontal = Self.edges[parts[1]], horizontal.axis == .horizontal else { return nil }
            self = .corner(vertical: vertical, horizontal: horizontal)
        case 3 where parts[2] == "sixth" && words.count == 1:
            guard let row = ["top", "bottom"].firstIndex(of: parts[0]), let column = Self.columnNames.firstIndex(of: parts[1]) else { return nil }
            self = .sixth(column: column, row: row)
        default:
            return nil
        }
    }

    public var text: String {
        func name(_ direction: Direction) -> String { Self.edges.first { $0.value == direction }!.key }
        switch self {
        case let .edge(edge, fraction):
            guard let fraction else { return name(edge) }
            let written = Self.fractions.first { abs($0.value - fraction) < 0.001 }?.text ?? "\(fraction)"
            return "\(name(edge)) \(written)"
        case let .corner(vertical, horizontal): return "\(name(vertical))-\(name(horizontal))"
        case .center: return "center"
        case let .sixth(column, row): return "\(row == 0 ? "top" : "bottom")-\(Self.columnNames[column])-sixth"
        // Spans only exist while placing; written down it's always the window's own
        case .column: return "column"
        }
    }

    /// "3/4" or "0.75", strictly between 0 and 1.
    private static func fraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/").compactMap { Double($0) }
        let value = parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : Double(text)
        return value.flatMap { (0.05...0.95).contains($0) ? $0 : nil }
    }
}

extension Settings.TitleRule {
    /// Why `pattern` can't be used as a title rule, or nil if it can.
    public static func problem(with pattern: String) -> String? {
        if pattern.isEmpty { return "Enter part of a window title, or a regular expression." }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "That isn't a valid regular expression. Escape ( ) [ ] . * + ? with \\ to match them literally."
        }
    }

    /// How many of `windows` this rule would float, matched the way `FloatRules` matches them.
    public func matches(in windows: [(app: String, title: String)]) -> Int {
        guard Self.problem(with: title) == nil else { return 0 }
        return windows.filter { FloatRules(apps: [], titles: [(app, title)]).floats(app: $0.app, title: $0.title) }.count
    }
}
