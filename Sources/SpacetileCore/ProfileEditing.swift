import CoreGraphics

/// Where a tile sits in a layout snapshot: the turns from the root, `false` for a split's first
/// child and `true` for its second.
public typealias TilePath = [Bool]

/// Editing operations behind the profile designer. An empty tile is a slot with no app yet;
/// loading closes it up like a closed window.
extension LayoutSnapshot {
    /// Starting layouts, all slots empty.
    public static let templates: [(name: String, layout: LayoutSnapshot)] = [
        ("Single", .tile([])),
        ("Halves", .split(axis: .horizontal, ratio: 0.5, first: .tile([]), second: .tile([]))),
        ("⅔ + ⅓", .split(axis: .horizontal, ratio: 2.0 / 3, first: .tile([]), second: .tile([]))),
        ("Thirds", .split(axis: .horizontal, ratio: 1.0 / 3, first: .tile([]),
                          second: .split(axis: .horizontal, ratio: 0.5, first: .tile([]), second: .tile([])))),
        ("Main + stack", .split(axis: .horizontal, ratio: 0.5, first: .tile([]),
                                second: .split(axis: .vertical, ratio: 0.5, first: .tile([]), second: .tile([])))),
        ("Rows", .split(axis: .vertical, ratio: 0.5, first: .tile([]), second: .tile([]))),
        ("Quarters", .split(axis: .horizontal, ratio: 0.5,
                            first: .split(axis: .vertical, ratio: 0.5, first: .tile([]), second: .tile([])),
                            second: .split(axis: .vertical, ratio: 0.5, first: .tile([]), second: .tile([])))),
    ]

    /// Every tile with its path, its windows and where it sits in `rect`.
    public func tiles(in rect: CGRect, gap: CGFloat) -> [(path: TilePath, refs: [WindowRef], rect: CGRect)] {
        switch self {
        case .tile(let refs):
            return [([], refs, rect)]
        case let .split(axis, ratio, first, second):
            let (a, b) = rect.split(along: axis, ratio: ratio, gap: gap)
            return first.tiles(in: a, gap: gap).map { ([false] + $0.path, $0.refs, $0.rect) }
                + second.tiles(in: b, gap: gap).map { ([true] + $0.path, $0.refs, $0.rect) }
        }
    }

    /// Every split's divider: its path, axis, the strip between its children, and the split's
    /// whole rect (what a dragged ratio is measured against).
    public func dividers(in rect: CGRect, gap: CGFloat) -> [(path: TilePath, axis: Axis, strip: CGRect, bounds: CGRect)] {
        guard case let .split(axis, ratio, first, second) = self else { return [] }
        let (a, b) = rect.split(along: axis, ratio: ratio, gap: gap)
        let strip = axis == .horizontal
            ? CGRect(x: a.maxX, y: rect.minY, width: b.minX - a.maxX, height: rect.height)
            : CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: b.minY - a.maxY)
        return [([], axis, strip, rect)]
            + first.dividers(in: a, gap: gap).map { ([false] + $0.path, $0.axis, $0.strip, $0.bounds) }
            + second.dividers(in: b, gap: gap).map { ([true] + $0.path, $0.axis, $0.strip, $0.bounds) }
    }

    public func node(at path: TilePath) -> LayoutSnapshot? {
        guard let turn = path.first else { return self }
        guard case let .split(_, _, first, second) = self else { return nil }
        return (turn ? second : first).node(at: Array(path.dropFirst()))
    }

    public func replacing(at path: TilePath, with node: LayoutSnapshot) -> LayoutSnapshot {
        guard let turn = path.first else { return node }
        guard case let .split(axis, ratio, first, second) = self else { return self }
        let rest = Array(path.dropFirst())
        return turn
            ? .split(axis: axis, ratio: ratio, first: first, second: second.replacing(at: rest, with: node))
            : .split(axis: axis, ratio: ratio, first: first.replacing(at: rest, with: node), second: second)
    }

    /// Splits the tile at `path`; its windows stay in the first half and the second is an empty slot.
    public func splitting(at path: TilePath, along axis: Axis) -> LayoutSnapshot {
        guard let tile = node(at: path) else { return self }
        return replacing(at: path, with: .split(axis: axis, ratio: 0.5, first: tile, second: .tile([])))
    }

    /// Removes the tile at `path`; its sibling takes the space. Removing the only tile leaves an empty slot.
    public func removing(at path: TilePath) -> LayoutSnapshot {
        guard let last = path.last else { return .tile([]) }
        let parentPath = Array(path.dropLast())
        guard case let .split(_, _, first, second)? = node(at: parentPath) else { return self }
        return replacing(at: parentPath, with: last ? first : second)
    }

    public func settingRatio(at path: TilePath, to ratio: Double) -> LayoutSnapshot {
        guard case let .split(axis, _, first, second)? = node(at: path) else { return self }
        return replacing(at: path, with: .split(axis: axis, ratio: ratio.clamped(to: BSPTree.ratioRange), first: first, second: second))
    }

    /// Puts `refs` into the empty slots of `self` in reading order, for applying a template to a
    /// Space that already had windows. Refs left over join the last slot as a stack.
    public func filled(with refs: [WindowRef]) -> LayoutSnapshot {
        let slots = tiles(in: CGRect(x: 0, y: 0, width: 1, height: 1), gap: 0)
        var remaining = refs[...]
        var result = self
        for slot in slots where slot.refs.isEmpty {
            guard let next = remaining.popFirst() else { break }
            result = result.replacing(at: slot.path, with: .tile([next]))
        }
        if !remaining.isEmpty, let last = result.tiles(in: CGRect(x: 0, y: 0, width: 1, height: 1), gap: 0).last {
            result = result.replacing(at: last.path, with: .tile(last.refs + remaining))
        }
        return result
    }
}

extension Profile {
    /// Numbers each app's windows in reading order (Spaces in order, then tiles, floating, others),
    /// so choosing Chrome in two slots means its first and second windows.
    public func renumbered() -> Profile {
        var counts: [String: Int] = [:]
        func number(_ refs: [WindowRef]) -> [WindowRef] {
            refs.map { ref in
                defer { counts[ref.app, default: 0] += 1 }
                return WindowRef(app: ref.app, index: counts[ref.app, default: 0])
            }
        }
        func walk(_ node: LayoutSnapshot) -> LayoutSnapshot {
            switch node {
            case .tile(let refs): .tile(number(refs))
            case let .split(axis, ratio, first, second):
                // Evaluated in order so the first child is numbered before the second
                { let a = walk(first); let b = walk(second); return .split(axis: axis, ratio: ratio, first: a, second: b) }()
            }
        }
        var copy = self
        copy.spaces = spaces.sorted { $0.space < $1.space }.map { space in
            var space = space
            space.tree = space.tree.map(walk)
            space.floating = number(space.floating)
            space.others = number(space.others)
            return space
        }
        return copy
    }
}

extension Profile {
    /// The icons the profile editor offers, in groups, each with a name for VoiceOver. Any SF Symbol
    /// name works in the file.
    public static let iconChoices: [(title: String, icons: [(symbol: String, name: String)])] = [
        ("Work", [("rectangle.stack", "Stack"), ("briefcase", "Briefcase"), ("laptopcomputer", "Laptop"),
                  ("desktopcomputer", "Desktop computer"), ("display.2", "Two displays"), ("keyboard", "Keyboard"),
                  ("terminal", "Terminal"), ("chevron.left.forwardslash.chevron.right", "Code"), ("hammer", "Hammer"),
                  ("wrench.and.screwdriver", "Tools"), ("ladybug", "Bug"), ("chart.bar", "Chart")]),
        ("People", [("bubble.left.and.bubble.right", "Chat"), ("envelope", "Mail"), ("phone", "Phone"),
                    ("video", "Video"), ("person", "Person"), ("person.2", "People"),
                    ("calendar", "Calendar"), ("megaphone", "Megaphone"), ("graduationcap", "Graduation cap"),
                    ("book", "Book"), ("doc.text", "Document"), ("newspaper", "Newspaper")]),
        ("Making", [("paintbrush", "Paintbrush"), ("pencil.and.ruler", "Pencil and ruler"), ("photo", "Photo"),
                    ("camera", "Camera"), ("music.note", "Music"), ("film", "Film"),
                    ("mic", "Microphone"), ("headphones", "Headphones"), ("gamecontroller", "Game controller"),
                    ("puzzlepiece", "Puzzle piece"), ("cube", "Cube"), ("sparkles", "Sparkles")]),
        ("Places", [("house", "House"), ("building.2", "Office"), ("airplane", "Airplane"),
                    ("car", "Car"), ("cup.and.saucer", "Coffee"), ("fork.knife", "Food"),
                    ("sun.max", "Sun"), ("moon", "Moon"), ("star", "Star"),
                    ("heart", "Heart"), ("bolt", "Bolt"), ("leaf", "Leaf")]),
    ]

    /// Sets the icon, storing nothing for the default so files stay as they were.
    public mutating func setIcon(_ symbol: String?) {
        icon = symbol == Self.defaultIcon ? nil : symbol
    }
}

/// `base`, or `base 2`, `base 3`… whichever is first free. (Joining `[base]` to an endless lazy
/// sequence with `+` builds the whole sequence first, which hung the app.)
public func uniqueProfileName(_ base: String, taken: Set<String>) -> String {
    if !taken.contains(base) { return base }
    return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
}

/// The file a profile is stored in. `/` can't appear in a file name, so it becomes `-`.
public func profileFileName(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "-") + ".json"
}

/// Why `name` can't be used for a profile, or nil if it can. `current` is the profile being renamed,
/// which may keep its own name. Names that differ only by `/` and `-`, or only by case (macOS disks
/// ignore case), would share a file, and a file name can't be longer than 255 bytes.
public func profileNameProblem(_ name: String, current: String? = nil, taken: Set<String>) -> String? {
    let name = name.trimmingCharacters(in: .whitespaces)
    if name.isEmpty { return "Enter a name." }
    if profileFileName(name).utf8.count > 255 { return "That name is too long." }
    let file = profileFileName(name).lowercased()
    guard let clash = taken.first(where: { $0 != current && profileFileName($0).lowercased() == file }) else { return nil }
    return clash == name ? "A profile called “\(name)” already exists." : "“\(name)” would share a file with “\(clash)”."
}
