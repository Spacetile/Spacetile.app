import CoreGraphics

/// Space IDs for one display's part of a Space shared by every display. Tagged with a high bit, so
/// they can't be mistaken for the window server's own IDs, with the real Space and a stable display
/// index packed below it.
public enum SpanningSpace {
    static let tag = 1 << 40

    public static func id(space: Int, display index: Int) -> Int { tag | space << 8 | index }

    /// The real Space and display index, or nil for an ID that isn't one of these.
    public static func decode(_ id: Int) -> (space: Int, display: Int)? {
        guard id & tag != 0 else { return nil }
        return ((id & ~tag) >> 8, id & 0xFF)
    }
}

/// Who a display is, beyond its name: names repeat (two identical monitors) and change with the
/// system language, while vendor, model and serial don't.
public struct DisplayIdentity: Codable, Hashable, Sendable {
    public var name: String
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var builtIn: Bool

    public init(name: String, vendor: UInt32 = 0, model: UInt32 = 0, serial: UInt32 = 0, builtIn: Bool = false) {
        self.name = name
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.builtIn = builtIn
    }

    /// `vendor-model-serial`, or the name for displays that report no serial. Profiles from before
    /// signatures stored names, which this makes match as before.
    public var signature: String { serial == 0 ? name : "\(vendor)-\(model)-\(serial)" }
}

/// A display as a profile records it: who it is, where it sat and how many Desktops it had.
public struct ProfileDisplay: Codable, Equatable, Sendable {
    public var identity: DisplayIdentity
    public var frame: CGRect
    public var desktops: Int

    public init(identity: DisplayIdentity, frame: CGRect, desktops: Int) {
        self.identity = identity
        self.frame = frame
        self.desktops = desktops
    }
}

/// How the window server lays out a full-screen app's Space: one tile, or two side by side in
/// Split View, read from the Space's `TileLayoutManager`. The windows on such a Space include
/// toolbar strips, dividers and helpers besides these; only the tiles are the app's windows.
public struct FullScreenTiles: Equatable, Sendable {
    public struct Tile: Equatable, Sendable {
        public let window: WindowID
        public let rect: CGRect

        public init(window: WindowID, rect: CGRect) {
            self.window = window
            self.rect = rect
        }
    }

    /// Left first.
    public let tiles: [Tile]
    /// What the tiles divide: the whole display, menu bar included.
    public let area: CGRect

    public init(tiles: [Tile], area: CGRect) {
        self.tiles = tiles.sorted { $0.rect.minX < $1.rect.minX }
        self.area = area
    }

    /// Reads a `type` 4 entry from `SLSCopyManagedDisplaySpaces`. Nil when it has no tiles, since
    /// the entry's shape is undocumented and has changed between releases.
    public init?(entry: [String: Any]) {
        guard let manager = entry["TileLayoutManager"] as? [String: Any],
              let spaces = manager["TileSpaces"] as? [[String: Any]] else { return nil }
        func number(_ value: Any?) -> Double? { value as? Double ?? (value as? Int).map(Double.init) }
        func rect(_ value: Any?) -> CGRect? {
            guard let value = value as? [String: Any], let width = number(value["Width"]), let height = number(value["Height"]) else { return nil }
            return CGRect(x: number(value["X"]) ?? 0, y: number(value["Y"]) ?? 0, width: width, height: height)
        }
        let tiles = spaces.compactMap { space -> Tile? in
            guard let id = (space["TileWindowID"] as? Int).flatMap(WindowID.init(exactly:)), let frame = rect(space["TileRect"]) else { return nil }
            return Tile(window: id, rect: frame)
        }
        guard !tiles.isEmpty else { return nil }
        self.init(tiles: tiles, area: rect(manager["Layout Rect"]) ?? tiles.reduce(CGRect.null) { $0.union($1.rect) })
    }

    public var windows: [WindowID] { tiles.map(\.window) }

    /// The left window's share of the width in Split View, nil for one app.
    public var ratio: Double? {
        guard tiles.count == 2, area.width > 0 else { return nil }
        return tiles[0].rect.width / area.width
    }
}

/// One display's Spaces as the window server lists them: its Desktops in Mission Control order,
/// the one showing, and where the display sits in global (top-left) coordinates.
public struct DisplaySpaces: Equatable, Sendable {
    public let id: String
    public let identity: DisplayIdentity
    public var name: String { identity.name }
    public let frame: CGRect
    /// Space IDs, Desktop 1 first. Full-screen app Spaces aren't Desktops and aren't listed.
    public let spaces: [Int]
    /// The Space showing: a Desktop, or a full-screen app's Space.
    public let current: Int
    /// Every Space in Mission Control order, full-screen ones included: what a swipe or ⌃←/→ steps
    /// through.
    public let order: [Int]
    /// How each full-screen Space's windows are tiled, where the window server says.
    public let fullScreen: [Int: FullScreenTiles]

    /// `order` defaults to the Desktops alone, for a display with no full-screen apps.
    public init(id: String, identity: DisplayIdentity, frame: CGRect, spaces: [Int], current: Int, order: [Int]? = nil,
                fullScreen: [Int: FullScreenTiles] = [:]) {
        self.id = id
        self.identity = identity
        self.frame = frame
        self.spaces = spaces
        self.current = current
        self.order = order ?? spaces
        self.fullScreen = fullScreen
    }

    /// Full-screen app Spaces in Mission Control order.
    public var fullScreenSpaces: [Int] { order.filter { !spaces.contains($0) } }

    public func isFullScreen(_ space: Int) -> Bool { order.contains(space) && !spaces.contains(space) }

    /// Swipes from the Space showing to `target`: positive steps right, negative left. Nil when
    /// either isn't on this display.
    public func steps(to target: Int, from start: Int? = nil) -> Int? {
        guard let to = order.firstIndex(of: target), let from = order.firstIndex(of: start ?? current) else { return nil }
        return to - from
    }

    /// The Desktop after (or before) `space` in Mission Control order, skipping full-screen Spaces
    /// and wrapping round. From a full-screen Space that's the Desktop beside it.
    public func desktop(after space: Int, forward: Bool) -> Int? {
        next(after: space, forward: forward) { spaces.contains($0) }
    }

    /// The full-screen Space after (or before) `space`, skipping Desktops and wrapping round.
    public func fullScreenSpace(after space: Int, forward: Bool) -> Int? {
        next(after: space, forward: forward) { !spaces.contains($0) }
    }

    private func next(after space: Int, forward: Bool, matching wanted: (Int) -> Bool) -> Int? {
        guard let start = order.firstIndex(of: space) else { return nil }
        for step in 1...order.count {
            let candidate = order[((start + (forward ? step : -step)) % order.count + order.count) % order.count]
            if candidate != space, wanted(candidate) { return candidate }
        }
        return nil
    }
}

/// Every display's Spaces, numbered per display as Mission Control labels them: each display has
/// its own Desktop 1, 2, 3…. Commands that take a number act on the active display, the one with
/// the menu bar.
public struct Desktops: Equatable, Sendable {
    /// Left to right, then top to bottom, the order next and previous display walk.
    public let displays: [DisplaySpaces]
    public let active: DisplaySpaces?
    /// One set of Spaces spans every display ("Displays have separate Spaces" off). Each display
    /// then lists the same Desktops under its own `SpanningSpace` IDs, so it can tile its own part.
    public let spansDisplays: Bool

    public init(displays: [DisplaySpaces], activeID: String?, spansDisplays: Bool = false) {
        self.displays = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        active = self.displays.first { $0.id == activeID } ?? self.displays.first
        self.spansDisplays = spansDisplays
    }

    /// Desktops when one set of Spaces spans every display: each screen gets the shared Desktops,
    /// keyed per display with `SpanningSpace`, and every display shows the same one. The active
    /// display is the main one, since the menu bar lives there in this mode.
    /// Full-screen Spaces in `order` keep their own IDs on every display: a full-screen window
    /// covers one display, and nothing tiles there.
    public static func spanning(screens: [(id: String, identity: DisplayIdentity, frame: CGRect, index: Int)],
                                spaces: [Int], current: Int, order: [Int]? = nil, fullScreen: [Int: FullScreenTiles] = [:]) -> Desktops {
        let displays = screens.map { screen in
            let id = { (space: Int) in spaces.contains(space) ? SpanningSpace.id(space: space, display: screen.index) : space }
            return DisplaySpaces(id: screen.id, identity: screen.identity, frame: screen.frame,
                                 spaces: spaces.map { SpanningSpace.id(space: $0, display: screen.index) },
                                 current: id(current), order: (order ?? spaces).map(id), fullScreen: fullScreen)
        }
        let main = displays.first { $0.frame.origin == .zero } ?? displays.first
        return Desktops(displays: displays, activeID: main?.id, spansDisplays: true)
    }

    /// The Space the window server knows for a Space ID: itself, or the shared Space behind a
    /// spanning display's ID.
    public func real(_ space: Int) -> Int { SpanningSpace.decode(space)?.space ?? space }

    /// The Space showing on the active display.
    public var activeSpace: Int? { active?.current }

    /// The Space showing on each display.
    public var visible: [Int] { displays.map(\.current) }

    public var allSpaces: [Int] { displays.flatMap(\.spaces) }

    /// The display holding a Space, Desktop or full-screen.
    public func display(of space: Int) -> DisplaySpaces? { displays.first { $0.order.contains(space) } }

    /// Whether `space` is a full-screen app's Space rather than a Desktop.
    public func isFullScreen(_ space: Int) -> Bool { display(of: space)?.isFullScreen(space) ?? false }

    /// A full-screen Space's tiles, nil for a Desktop or when the window server didn't say.
    public func tiles(of space: Int) -> FullScreenTiles? { display(of: space)?.fullScreen[space] }

    /// A Space's Desktop number on its own display, or nil for a full-screen app Space.
    public func number(of space: Int) -> Int? {
        display(of: space).flatMap { $0.spaces.firstIndex(of: space) }.map { $0 + 1 }
    }

    /// A Space's position on its display in Mission Control order, full-screen Spaces counted: the
    /// number ⌥N and the menu bar use. Labels, rules, layouts and profiles stay with Desktop numbers
    /// (`number(of:)`), so they keep to their Desktop when a full-screen app opens before it.
    public func position(of space: Int) -> Int? {
        display(of: space).flatMap { $0.order.firstIndex(of: space) }.map { $0 + 1 }
    }

    /// The Space at `position` on `display`, a Desktop or a full-screen app's.
    public func space(position: Int, on display: DisplaySpaces) -> Int? {
        display.order.indices.contains(position - 1) ? display.order[position - 1] : nil
    }

    /// Desktop `number` on `display`, if it has that many.
    public func space(number: Int, on display: DisplaySpaces) -> Int? {
        display.spaces.indices.contains(number - 1) ? display.spaces[number - 1] : nil
    }

    /// The display after (or before) `display`, wrapping round, or nil when there's only one.
    public func neighbor(of display: DisplaySpaces, forward: Bool) -> DisplaySpaces? {
        guard displays.count > 1, let index = displays.firstIndex(of: display) else { return nil }
        return displays[(index + (forward ? 1 : -1) + displays.count) % displays.count]
    }

    public func display(containing point: CGPoint) -> DisplaySpaces? { displays.first { $0.frame.contains(point) } }

    /// Whether the left (or right) edge of `display` borders no other display. Only outer edges send
    /// a dragged window to another Space; a shared edge is just the way onto the next display.
    public func isOuterEdge(right: Bool, of display: DisplaySpaces) -> Bool {
        let probe = CGPoint(x: right ? display.frame.maxX + 1 : display.frame.minX - 1, y: display.frame.midY)
        return !displays.contains { $0.frame.contains(probe) }
    }

    /// The connected displays by name, as profiles named them before signatures. Kept for the
    /// automatic-load setting, which shows names.
    public var fingerprint: String { displays.map(\.name).sorted().joined(separator: " + ") }

    /// The connected displays by signature, which profiles record to know their displays again.
    public var signatures: Set<String> { Set(displays.map(\.identity.signature)) }

    /// Pairs each recorded display with a connected one, one to one: same signature first, then
    /// same name, then same role (built-in for built-in, externals for externals, biggest first).
    /// Keyed by the recorded display's signature, which is what profile Spaces store.
    public func assign(_ recorded: [DisplayIdentity]) -> [String: DisplaySpaces] {
        var free = displays
        var assigned: [String: DisplaySpaces] = [:]
        func take(_ test: (DisplayIdentity, DisplaySpaces) -> Bool) {
            for identity in recorded where assigned[identity.signature] == nil {
                guard let index = free.firstIndex(where: { test(identity, $0) }) else { continue }
                assigned[identity.signature] = free.remove(at: index)
            }
        }
        take { $0.signature == $1.identity.signature }
        take { $0.name == $1.name }
        free.sort { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        take { $0.builtIn == $1.identity.builtIn }
        return assigned
    }
}

/// Where one of a profile's Spaces goes on the displays connected now, and why.
public struct ProfilePlacement: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Its display, or one standing in for it, has that Desktop.
        case matched
        /// Its display isn't connected: it goes after the main display's own Desktops, where macOS
        /// puts a disconnected display's Spaces.
        case appended(onto: String)
        /// Its display (or the main display, when appended) doesn't have that many Desktops.
        case noRoom
    }

    public let snapshot: SpaceSnapshot
    /// The Space it goes to, or nil when there's no room.
    public let space: Int?
    public let display: DisplaySpaces?
    public let number: Int
    public let reason: Reason
}

extension Desktops {
    /// The display with the menu bar in System Settings' arrangement, which macOS moves a
    /// disconnected display's Spaces onto. Its frame starts at the origin.
    public var main: DisplaySpaces? { displays.first { $0.frame.origin == .zero } ?? active }

    /// Where each of a profile's Spaces goes on the displays connected now.
    public func place(_ profile: Profile) -> [ProfilePlacement] {
        let recorded = profile.recordedDisplays
        let assigned = assign(recorded)
        // Desktops each recorded display had: recorded counts, or the highest Desktop used in older profiles
        func desktops(of identity: DisplayIdentity) -> Int {
            profile.displays?.first { $0.identity == identity }?.desktops
                ?? profile.spaces.filter { $0.display == identity.signature }.map(\.space).max() ?? 0
        }
        // Missing displays' Desktops sit after the main display's own, one display after another
        let missing = recorded.filter { assigned[$0.signature] == nil }
        let appendedCount = missing.map(desktops).reduce(0, +)
        var offsets: [String: Int] = [:]
        var next = max((main?.spaces.count ?? 0) - appendedCount, 0)
        for identity in missing {
            offsets[identity.signature] = next
            next += desktops(of: identity)
        }
        // Explicit types and no local named `space`: Xcode 26's compiler crashes inferring this closure otherwise
        return profile.spaces.map { snapshot -> ProfilePlacement in
            let stored = snapshot.display
            if let stored, let offset = offsets[stored], let main {
                let number = offset + snapshot.space
                let target: Int? = space(number: number, on: main)
                return ProfilePlacement(snapshot: snapshot, space: target, display: main, number: number,
                                        reason: target == nil ? .noRoom : .appended(onto: main.name))
            }
            // Its own display, a stand-in, or (no display recorded) the main one: not the active
            // display, or where it lands would change with focus
            let display = stored.flatMap { assigned[$0] } ?? main
            let target: Int? = display.flatMap { space(number: snapshot.space, on: $0) }
            return ProfilePlacement(snapshot: snapshot, space: target, display: display, number: snapshot.space,
                                    reason: target == nil ? .noRoom : .matched)
        }
    }

    /// Whether a profile was captured in the Spaces mode in effect now: spanning displays or separate.
    public func sameMode(as profile: Profile) -> Bool { (profile.spansDisplays ?? false) == spansDisplays }

    /// Whether these are exactly the displays a profile was captured on, in the same Spaces mode,
    /// which automatic applying needs. Profiles from before signatures compare display names.
    public func matchesExactly(_ profile: Profile) -> Bool {
        guard sameMode(as: profile) else { return false }
        if let recorded = profile.displays { return Set(recorded.map(\.identity.signature)) == signatures }
        return profile.display == fingerprint
    }
}

/// How displays sit relative to each other, for drawing them as System Settings ▸ Displays does.
public enum Arrangement {
    /// Displays in reading order: those whose vertical extents overlap share a row, left to right,
    /// and rows run top to bottom. Returns indices into `frames`.
    public static func rows(_ frames: [CGRect]) -> [[Int]] {
        var rows: [[Int]] = []
        for index in frames.indices.sorted(by: { frames[$0].minY < frames[$1].minY }) {
            let frame = frames[index]
            if let row = rows.firstIndex(where: { $0.contains { frames[$0].minY < frame.maxY && frame.minY < frames[$0].maxY } }) {
                rows[row].append(index)
            } else {
                rows.append([index])
            }
        }
        return rows.map { $0.sorted { frames[$0].minX < frames[$1].minX } }
    }

    /// `frames` scaled and moved to fit `size`, keeping their proportions and positions.
    public static func fit(_ frames: [CGRect], in size: CGSize) -> [CGRect] {
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return frames }
        let scale = min(size.width / bounds.width, size.height / bounds.height)
        let offset = CGPoint(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
        return frames.map {
            CGRect(x: ($0.minX - bounds.minX) * scale + offset.x, y: ($0.minY - bounds.minY) * scale + offset.y,
                   width: $0.width * scale, height: $0.height * scale)
        }
    }
}

/// The layouts of displays that went away, by display signature, given back when the display
/// returns. With Spaces spanning displays a departing display's windows move to the others, which
/// empties its layouts; when it returns its windows would come back one at a time and lose their
/// arrangement.
public struct DepartedLayouts: Sendable {
    private var saved: [String: [Int: SpaceLayout]] = [:]

    public init() {}

    /// Notes the displays that left or returned between `old` and `new`. Returns the saved layouts
    /// of returned displays, by Space, for Spaces whose layout in `layouts` is empty now.
    public mutating func update(from old: Desktops, to new: Desktops, layouts: [Int: SpaceLayout]) -> [Int: SpaceLayout] {
        let oldIDs = Set(old.displays.map(\.id)), newIDs = Set(new.displays.map(\.id))
        for gone in old.displays where !newIDs.contains(gone.id) {
            saved[gone.identity.signature] = layouts.filter { old.display(of: $0.key)?.id == gone.id && !$0.value.tree.windows.isEmpty }
        }
        var returned: [Int: SpaceLayout] = [:]
        for back in new.displays where !oldIDs.contains(back.id) {
            for (space, layout) in saved.removeValue(forKey: back.identity.signature) ?? [:]
            where new.display(of: space)?.id == back.id && layouts[space]?.tree.windows.isEmpty ?? true {
                returned[space] = layout
            }
        }
        return returned
    }
}
