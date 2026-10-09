import CoreGraphics
import Foundation

/// A window identified in a way that survives relaunching apps: its app's bundle ID and its
/// position among that app's windows, ordered by window number (creation order).
/// Encoded as `"bundle.id#index"`, e.g. `"com.google.Chrome#1"` for Chrome's second window.
public struct WindowRef: Codable, Hashable, Sendable {
    public var app: String
    public var index: Int

    public init(app: String, index: Int) {
        self.app = app
        self.index = index
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let hash = text.lastIndex(of: "#"), let index = Int(text[text.index(after: hash)...]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected \"bundle.id#index\", got \"\(text)\""))
        }
        self.init(app: String(text[..<hash]), index: index)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("\(app)#\(index)")
    }

    /// Numbers each app's windows from 0 in window-number order.
    public static func assign(_ windows: [(id: WindowID, app: String)]) -> [WindowID: WindowRef] {
        var counts: [String: Int] = [:]
        var refs: [WindowID: WindowRef] = [:]
        for window in windows.sorted(by: { $0.id < $1.id }) {
            let index = counts[window.app, default: 0]
            counts[window.app] = index + 1
            refs[window.id] = WindowRef(app: window.app, index: index)
        }
        return refs
    }
}

/// A layout tree with windows replaced by refs, so it can be saved and restored.
/// In JSON a tile is an array of refs and a split is `{"axis", "ratio", "first", "second"}`.
public indirect enum LayoutSnapshot: Codable, Equatable, Sendable {
    case tile([WindowRef])
    case split(axis: Axis, ratio: Double, first: LayoutSnapshot, second: LayoutSnapshot)

    private enum Keys: String, CodingKey { case axis, ratio, first, second }

    public init(from decoder: Decoder) throws {
        if let refs = try? decoder.singleValueContainer().decode([WindowRef].self) {
            self = .tile(refs)
            return
        }
        let split = try decoder.container(keyedBy: Keys.self)
        self = try .split(axis: split.decode(Axis.self, forKey: .axis), ratio: split.decode(Double.self, forKey: .ratio),
                          first: split.decode(LayoutSnapshot.self, forKey: .first), second: split.decode(LayoutSnapshot.self, forKey: .second))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .tile(let refs):
            var container = encoder.singleValueContainer()
            try container.encode(refs)
        case let .split(axis, ratio, first, second):
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

/// One Space as captured: its layout and every window on it.
public struct SpaceSnapshot: Codable, Equatable, Sendable {
    public var space: Int
    public var mode: LayoutMode
    public var tree: LayoutSnapshot?
    public var floating: [WindowRef]
    /// Windows on this Space that weren't laid out when captured (Space never visited).
    public var others: [WindowRef]
    /// The display the Space was on: its signature, or its name in older profiles. `space` counts
    /// Desktops on that display. Absent in profiles from before multi-display, which go to the
    /// active display.
    public var display: String?

    public var windows: [WindowRef] { (tree.map(Self.refs) ?? []) + floating + others }

    public init(space: Int, mode: LayoutMode, tree: LayoutSnapshot?, floating: [WindowRef], others: [WindowRef], display: String? = nil) {
        self.space = space
        self.display = display
        self.mode = mode
        self.tree = tree
        self.floating = floating
        self.others = others
    }

    /// Hand-written profiles may leave out `mode` (bsp) and empty `floating`/`others`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(space: container.decode(Int.self, forKey: .space),
                      mode: container.decodeIfPresent(LayoutMode.self, forKey: .mode) ?? .bsp,
                      tree: container.decodeIfPresent(LayoutSnapshot.self, forKey: .tree),
                      floating: container.decodeIfPresent([WindowRef].self, forKey: .floating) ?? [],
                      others: container.decodeIfPresent([WindowRef].self, forKey: .others) ?? [],
                      display: container.decodeIfPresent(String.self, forKey: .display))
    }

    private static func refs(_ node: LayoutSnapshot) -> [WindowRef] {
        switch node {
        case .tile(let refs): refs
        case let .split(_, _, first, second): Self.refs(first) + Self.refs(second)
        }
    }
}

/// A full-screen app's Space as captured: its window, or two side by side in Split View. macOS
/// adds a new full-screen Space after the last Desktop and nothing can move it, so applying makes
/// the window full screen where it is, and Desktop numbers stay as they were.
public struct FullScreenSnapshot: Codable, Equatable, Sendable {
    /// One window, or two in Split View, left first.
    public var windows: [WindowRef]

    public init(windows: [WindowRef]) {
        self.windows = windows
    }
}

/// A saved arrangement of windows across Spaces, loaded by hand or when its display connects.
public struct Profile: Codable, Equatable, Sendable {
    public var name: String
    /// The display names, joined with " + ", the profile was captured on. Profiles from before
    /// `autoApply` applied themselves when these connected; now that needs `autoApply` on.
    public var display: String?
    /// Apply this profile when exactly its displays are connected, in the same Spaces mode. Off
    /// unless turned on.
    public var autoApply: Bool?
    /// Whether Spaces spanned displays ("Displays have separate Spaces" off) when captured. Absent in
    /// profiles from before, which were all captured with separate Spaces.
    public var spansDisplays: Bool?
    /// The displays captured, with where they sat and their Desktop counts. Absent in profiles from
    /// before signatures, whose Spaces name their display instead.
    public var displays: [ProfileDisplay]?
    public var spaces: [SpaceSnapshot]
    /// The Space to switch to once loaded.
    public var show: Int?
    /// Hide running apps the profile doesn't mention.
    public var hideUnlisted: Bool?
    /// Quit running apps the profile doesn't mention (asks first until told not to). Wins over `hideUnlisted`.
    public var quitUnlisted: Bool?
    /// Full-screen apps, made full screen again after the Desktops are arranged.
    public var fullScreen: [FullScreenSnapshot]?
    /// The SF Symbol that stands for the profile in lists and the menu bar; nil means `defaultIcon`.
    public var icon: String?
    /// What to open in each app, by bundle ID, when applying the profile launches it: links, files,
    /// folders and `$ commands` (see `LaunchItem`). An app that's already running is left alone, and
    /// one that restores its own windows keeps them, the items opening alongside.
    public var open: [String: [String]]?

    public init(name: String, display: String?, displays: [ProfileDisplay]? = nil, spansDisplays: Bool? = nil,
                spaces: [SpaceSnapshot], show: Int? = nil, hideUnlisted: Bool? = nil, quitUnlisted: Bool? = nil,
                fullScreen: [FullScreenSnapshot]? = nil, icon: String? = nil, open: [String: [String]]? = nil) {
        self.fullScreen = fullScreen
        self.open = open
        self.name = name
        self.icon = icon
        self.spansDisplays = spansDisplays
        self.display = display
        self.displays = displays
        self.spaces = spaces
        self.show = show
        self.hideUnlisted = hideUnlisted
        self.quitUnlisted = quitUnlisted
    }

    /// The displays the profile was captured on. Older profiles only name them on their Spaces, so
    /// those names stand in (a name is its own signature when there's no serial).
    public var recordedDisplays: [DisplayIdentity] {
        displays?.map(\.identity) ?? Array(Set(spaces.compactMap(\.display))).sorted().map { DisplayIdentity(name: $0) }
    }

    /// The icon profiles have until one is chosen.
    public static let defaultIcon = "rectangle.stack"

    /// Every app the profile places a window for.
    public var apps: Set<String> { Set((spaces.flatMap(\.windows) + (fullScreen ?? []).flatMap(\.windows)).map(\.app)) }

    /// Every app applying launches when it isn't running: the apps it places windows for, and the
    /// apps it opens something in.
    public var launchedApps: Set<String> { apps.union((open ?? [:]).filter { !items(opening: $0.key).isEmpty }.keys) }

    /// What to open in `app` when applying launches it, in order; blank lines are skipped.
    public func items(opening app: String) -> [LaunchItem] {
        (open?[app] ?? []).compactMap(LaunchItem.init)
    }

    /// Sets what to open in `app`, dropping blank lines, and the field once nothing is left.
    public mutating func setItems(_ lines: [String], opening app: String) {
        let kept = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var all = open ?? [:]
        all[app] = kept.isEmpty ? nil : kept
        open = all.isEmpty ? nil : all
    }
}

/// One line of a profile's `open` list, read from how it starts:
/// - `/` or `~`: a file or folder, opened in the app;
/// - `$`: a shell command, run in a new window or tab of a terminal app;
/// - anything with a scheme (`https://…`, `mailto:…`): a link;
/// - anything else is a web address, so `github.com` opens `https://github.com`.
public enum LaunchItem: Equatable, Sendable {
    case link(String)
    case path(String)
    case command(String)

    public init?(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return nil }
        switch first {
        case "/", "~":
            self = .path(text)
        case "$":
            let command = text.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            self = .command(command)
        default:
            self = .link(Self.hasScheme(text) ? text : "https://" + text)
        }
    }

    /// `scheme:` with something after it that isn't a port number, so `localhost:3000` is a web
    /// address and `mailto:me@example.com` a link.
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard let start = scheme.first, start.isASCII, start.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) else { return false }
        let rest = text[text.index(after: colon)...]
        return rest.hasPrefix("//") || !(rest.first?.isNumber ?? true)
    }
}

extension SpaceLayout {
    /// Captures this layout, naming windows by `ref`. Windows without a ref are left out.
    public func snapshot(space: Int, others: [WindowRef] = [], ref: (WindowID) -> WindowRef?) -> SpaceSnapshot {
        func walk(_ node: Node) -> LayoutSnapshot? {
            switch node {
            case .tile(let windows):
                let refs = windows.compactMap(ref)
                return refs.isEmpty ? nil : .tile(refs)
            case let .split(axis, ratio, first, second):
                switch (walk(first), walk(second)) {
                case let (a?, b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil): return nil
                }
            }
        }
        return SpaceSnapshot(space: space, mode: mode, tree: tree.root.flatMap(walk),
                               floating: floating.compactMap(ref).sorted { ($0.app, $0.index) < ($1.app, $1.index) },
                               others: others)
    }

    /// Rebuilds a layout from a snapshot. A ref that `resolve` can't match yet keeps its place as an
    /// empty tile waiting for its app: the app's next window fills it (see `add`). Empty tiles in the
    /// snapshot itself close up.
    public init(snapshot: SpaceSnapshot, resolve: (WindowRef) -> WindowID?) {
        var holes = BSPTree.firstHole
        var waiting: [WindowID: String] = [:]
        func walk(_ node: LayoutSnapshot) -> Node? {
            switch node {
            case .tile(let refs):
                let windows = refs.map { ref -> WindowID in
                    if let id = resolve(ref) { return id }
                    defer { holes += 1 }
                    waiting[holes] = ref.app
                    return holes
                }
                return windows.isEmpty ? nil : .tile(windows)
            case let .split(axis, ratio, first, second):
                switch (walk(first), walk(second)) {
                case let (a?, b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil): return nil
                }
            }
        }
        self.init(mode: snapshot.mode)
        tree = BSPTree(root: snapshot.tree.flatMap(walk))
        self.waiting = waiting
        nextHole = holes
        floating = Set(snapshot.floating.compactMap(resolve))
    }
}
