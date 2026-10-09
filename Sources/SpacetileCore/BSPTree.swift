import CoreGraphics

/// A binary space partition of one Space's tiled windows, yabai style.
public indirect enum Node: Equatable, Sendable {
    /// One tile. More than one window makes it a stack, front window first.
    case tile([WindowID])
    /// `ratio` is the share of the split's length given to `first`.
    case split(axis: Axis, ratio: Double, first: Node, second: Node)

    public static func leaf(_ window: WindowID) -> Node { .tile([window]) }
}

public enum Rotation: Sendable { case quarter, half, threeQuarter }

/// Smallest sizes windows have been seen to accept. Windows absent from it are assumed to fit anywhere.
public typealias MinimumSizes = [WindowID: CGSize]

public struct BSPTree: Equatable, Sendable {
    public internal(set) var root: Node?

    public static let ratioRange = 0.1...0.9

    /// Holes are virtual windows: empty tiles that keep a placement's shape when there aren't enough
    /// real windows to fill it. They use IDs no window server window has.
    public static let firstHole: WindowID = 0xFFFF_0000
    public static func isHole(_ id: WindowID) -> Bool { id >= firstHole }

    public init(root: Node? = nil) {
        self.root = root
    }

    /// Real windows in tree order (depth first, first child before second, stacks front first).
    public var windows: [WindowID] { leaves.filter { !Self.isHole($0) } }

    /// Holes in tree order.
    public var holes: [WindowID] { leaves.filter(Self.isHole) }

    /// Every leaf, holes included.
    var leaves: [WindowID] { root.map(Self.leaves) ?? [] }

    public func contains(_ window: WindowID) -> Bool { windows.contains(window) }

    /// The windows sharing `window`'s tile, front first.
    public func stack(containing window: WindowID) -> [WindowID] {
        tiles(in: .zero, gap: 0).first { $0.windows.contains(window) }?.windows ?? []
    }

    /// Splits `target`'s tile (or the last tile when `target` is absent) to make room for `window`.
    /// Without `preselect` the split runs along the tile's longer side and the new window takes
    /// the second half (yabai `window_placement second_child`). The existing window keeps `ratio`
    /// of the tile. When either part would be smaller than a known minimum size, `window` joins the
    /// tile as the front of a stack instead.
    public mutating func insert(
        _ window: WindowID, beside target: WindowID?, in bounds: CGRect, gap: CGFloat = 0,
        preselect: Direction? = nil, ratio: Double = 0.5, minimumSizes: MinimumSizes = [:],
        keeping kept: Set<WindowID> = []
    ) {
        guard let root, !contains(window) else {
            if self.root == nil { self.root = .leaf(window) }
            return
        }
        // Only holes left: the window takes the first free one, or splits beside a hole kept for
        // another window
        let free = holes.filter { !kept.contains($0) }
        guard let anchor = target.flatMap({ contains($0) ? $0 : nil }) ?? windows.last ?? (free.isEmpty ? holes.last : nil) else {
            return replace(free[0], with: window)
        }
        let all = tiles(in: bounds, gap: gap)
        let preferred = all.first { $0.windows.contains(anchor) }!
        let newFirst = preselect?.isLeading ?? false
        let splitRatio = newFirst ? 1 - ratio : ratio
        func natural(_ rect: CGRect) -> Axis { rect.width >= rect.height ? .horizontal : .vertical }
        // Where to split: the preferred tile along its longer side; a preselection says exactly
        // where. Failing that, the roomiest tile that can take the window either way, so a window
        // is only stacked out of sight when no tile has room for it
        var choices: [(tile: (windows: [WindowID], rect: CGRect), axis: Axis)] = [(preferred, preselect?.axis ?? natural(preferred.rect))]
        if preselect == nil {
            // Holes are left alone: they keep a profile's shape for windows still to come
            let others = all.filter { $0.windows != preferred.windows && !$0.windows.allSatisfy(Self.isHole) }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            for tile in [preferred] + others {
                let first = natural(tile.rect), second: Axis = first == .horizontal ? .vertical : .horizontal
                for axis in [first, second] where !(tile.windows == preferred.windows && axis == choices[0].axis) {
                    choices.append((tile, axis))
                }
            }
        }
        let fitting = choices.first { choice in
            let (a, b) = choice.tile.rect.split(along: choice.axis, ratio: splitRatio, gap: gap)
            let (newRect, oldRect) = newFirst ? (a, b) : (b, a)
            return Self.fits([window], in: newRect, minimumSizes, gap: gap) && Self.fits(choice.tile.windows, in: oldRect, minimumSizes, gap: gap)
        }

        guard let fitting, let host = fitting.tile.windows.first else {
            self.root = Self.replacingTile(containing: anchor, in: root) { .tile([window] + $0) }
            return
        }
        self.root = Self.replacingTile(containing: host, in: root) { windows in
            .split(axis: fitting.axis, ratio: splitRatio,
                   first: newFirst ? .leaf(window) : .tile(windows),
                   second: newFirst ? .tile(windows) : .leaf(window))
        }
    }

    /// Puts `new` where `old` is, e.g. a window filling a hole.
    public mutating func replace(_ old: WindowID, with new: WindowID) {
        root = root.map { Self.mapTiles($0) { $0.map { $0 == old ? new : $0 } } }
    }

    public mutating func removeHoles() {
        for hole in holes { remove(hole) }
    }

    /// Removes `window`; a tile left empty gives its space to its sibling.
    public mutating func remove(_ window: WindowID) {
        root = root.flatMap { Self.removing(window, from: $0) }
    }

    /// Where a window sits, so it can go back after leaving the tree for a while (native full screen).
    public enum Slot: Equatable, Sendable {
        /// One of a stack: rejoins the tile holding any of `others`, at `index`.
        case stacked(others: [WindowID], index: Int)
        /// Alone in its tile on one side of a split. `siblings` are the leaves on the other side.
        case split(axis: Axis, ratio: Double, isFirst: Bool, siblings: [WindowID])
        /// The only tile on the Space.
        case alone
    }

    public func slot(of window: WindowID) -> Slot? {
        func find(_ node: Node) -> Slot? {
            switch node {
            case .tile(let windows):
                guard let index = windows.firstIndex(of: window) else { return nil }
                return windows.count == 1 ? .alone : .stacked(others: windows.filter { $0 != window }, index: index)
            case let .split(axis, ratio, first, second):
                if first == .leaf(window) { return .split(axis: axis, ratio: ratio, isFirst: true, siblings: Self.leaves(second)) }
                if second == .leaf(window) { return .split(axis: axis, ratio: ratio, isFirst: false, siblings: Self.leaves(first)) }
                return find(first) ?? find(second)
            }
        }
        return root.flatMap(find)
    }

    /// Puts `window` back in `slot`: into its old stack, or splitting the smallest part of the tree
    /// that holds what was on the other side of its split, on the same side and with the same ratio.
    /// Returns false when none of its old neighbours are left, for the caller to place it as new.
    public mutating func reinsert(_ window: WindowID, at slot: Slot) -> Bool {
        guard let root, !contains(window) else { return false }
        let present = Set(leaves)
        switch slot {
        case .alone:
            return false
        case let .stacked(others, index):
            guard let mate = others.first(where: present.contains) else { return false }
            self.root = Self.mapTiles(root) { windows in
                guard windows.contains(mate) else { return windows }
                var windows = windows
                windows.insert(window, at: min(index, windows.count))
                return windows
            }
        case let .split(axis, ratio, isFirst, siblings):
            let remaining = Set(siblings).intersection(present)
            guard !remaining.isEmpty else { return false }
            self.root = Self.wrapping(root, covering: remaining) { node in
                .split(axis: axis, ratio: ratio, first: isFirst ? .leaf(window) : node, second: isFirst ? node : .leaf(window))
            }
        }
        return true
    }

    /// Replaces the smallest subtree whose leaves include all of `leaves` with `build(subtree)`.
    private static func wrapping(_ node: Node, covering leaves: Set<WindowID>, with build: (Node) -> Node) -> Node {
        if case let .split(axis, ratio, first, second) = node {
            if leaves.isSubset(of: Self.leaves(first)) {
                return .split(axis: axis, ratio: ratio, first: wrapping(first, covering: leaves, with: build), second: second)
            }
            if leaves.isSubset(of: Self.leaves(second)) {
                return .split(axis: axis, ratio: ratio, first: first, second: wrapping(second, covering: leaves, with: build))
            }
        }
        return build(node)
    }

    /// Each tile's windows and rect.
    public func tiles(in bounds: CGRect, gap: CGFloat) -> [(windows: [WindowID], rect: CGRect)] {
        var result: [(windows: [WindowID], rect: CGRect)] = []
        func walk(_ node: Node, _ rect: CGRect) {
            switch node {
            case .tile(let windows):
                result.append((windows, rect))
            case let .split(axis, ratio, first, second):
                let (a, b) = rect.split(along: axis, ratio: ratio, gap: gap)
                walk(first, a)
                walk(second, b)
            }
        }
        root.map { walk($0, bounds) }
        return result
    }

    /// Every window gets its tile's rect, so stacked windows overlap exactly.
    public func frames(in bounds: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: tiles(in: bounds, gap: gap).flatMap { tile in tile.windows.map { ($0, tile.rect) } })
    }

    /// Swaps two windows. Swapping with a hole moves the window into the hole and closes its old tile.
    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        if Self.isHole(b) {
            remove(a)
            replace(b, with: a)
            return
        }
        root = root.map {
            Self.mapTiles($0) { $0.map { $0 == a ? b : $0 == b ? a : $0 } }
        }
    }

    /// Rotates `window`'s stack so it's in front, keeping the cyclic order so next/previous
    /// keep walking the same way round.
    public mutating func bringToFront(_ window: WindowID) {
        root = root.map {
            Self.mapTiles($0) { windows in
                guard let index = windows.firstIndex(of: window) else { return windows }
                return Array(windows[index...] + windows[..<index])
            }
        }
    }

    /// Splits stacks back out where there's room, moves borders so every tile has room for its
    /// windows where the space allows, then merges tiles still too small into a neighbouring tile.
    /// Repeats until stable: each step changes the tile count by one in a single direction for a
    /// given set of minimum sizes.
    public mutating func normalize(in bounds: CGRect, gap: CGFloat, minimumSizes: MinimumSizes) {
        guard let start = root else { return }
        var node = start
        while let unstacked = Self.unstackingOne(node, rect: bounds, gap: gap, minimumSizes) { node = unstacked }
        node = Self.fitting(node, rect: bounds, gap: gap, minimumSizes)
        while let merged = Self.mergingOneOverflow(node, rect: bounds, gap: gap, minimumSizes) { node = merged }
        root = node
    }

    /// Whether some tile is too small for its windows' minimum sizes, which `normalize` would stack.
    public func overflows(in bounds: CGRect, gap: CGFloat, minimumSizes: MinimumSizes) -> Bool {
        root.map { Self.mergingOneOverflow($0, rect: bounds, gap: gap, minimumSizes) != nil } ?? false
    }

    /// Moves the nearest border of `window`'s tile that divides along `axis` by `points`
    /// (negative is west/north). The deepest enclosing split on that axis is used, whichever
    /// side of it the window is on, so h/l always move the same vertical border.
    public mutating func moveBorder(of window: WindowID, along axis: Axis, by points: CGFloat, in bounds: CGRect) {
        guard let root else { return }
        self.root = Self.adjustingNearestSplit(containing: window, in: root, rect: bounds, where: { splitAxis, _ in splitAxis == axis }) { ratio, rect in
            ratio + Double(points / rect.length(along: axis))
        }
    }

    /// Moves one specific edge of `window`'s tile by `points` (negative is west/north), as when the
    /// user drags that edge with the mouse. Does nothing for an edge on the screen border.
    public mutating func moveEdge(_ edge: Direction, of window: WindowID, by points: CGFloat, in bounds: CGRect) {
        guard let root else { return }
        // An east/south edge is the split line when the window sits in the first child, west/north in the second
        self.root = Self.adjustingNearestSplit(containing: window, in: root, rect: bounds,
                                               where: { axis, inFirst in axis == edge.axis && inFirst != edge.isLeading }) { ratio, rect in
            ratio + Double(points / rect.length(along: edge.axis))
        }
    }

    /// Flips the split that directly contains `window`'s tile between side by side and stacked.
    public mutating func toggleSplit(ofParentOf window: WindowID) {
        func walk(_ node: Node) -> Node {
            guard case let .split(axis, ratio, first, second) = node else { return node }
            let windowTile: (Node) -> Bool = { if case .tile(let windows) = $0 { windows.contains(window) } else { false } }
            if windowTile(first) || windowTile(second) {
                return .split(axis: axis.flipped, ratio: ratio, first: first, second: second)
            }
            return .split(axis: axis, ratio: ratio, first: walk(first), second: walk(second))
        }
        root = root.map(walk)
    }

    /// Removes holes, then gives every tile an equal share along each run of same-axis splits.
    public mutating func balance() {
        removeHoles()
        func weight(_ node: Node, _ axis: Axis) -> Int {
            guard case let .split(nodeAxis, _, first, second) = node, nodeAxis == axis else { return 1 }
            return weight(first, axis) + weight(second, axis)
        }
        func walk(_ node: Node) -> Node {
            guard case let .split(axis, _, first, second) = node else { return node }
            let a = weight(first, axis), b = weight(second, axis)
            return .split(axis: axis, ratio: Double(a) / Double(a + b), first: walk(first), second: walk(second))
        }
        root = root.map(walk)
    }

    /// Mirrors across `axis`: `.horizontal` swaps left/right children, `.vertical` swaps top/bottom.
    public mutating func mirror(_ axis: Axis) {
        func walk(_ node: Node) -> Node {
            guard case let .split(nodeAxis, ratio, first, second) = node else { return node }
            return nodeAxis == axis
                ? .split(axis: nodeAxis, ratio: 1 - ratio, first: walk(second), second: walk(first))
                : .split(axis: nodeAxis, ratio: ratio, first: walk(first), second: walk(second))
        }
        root = root.map(walk)
    }

    /// Rotates clockwise: a quarter turn moves left→top and top→right.
    public mutating func rotate(_ rotation: Rotation) {
        func walk(_ node: Node) -> Node {
            guard case let .split(axis, ratio, first, second) = node else { return node }
            let swapChildren = switch rotation {
            case .quarter: axis == .vertical
            case .half: true
            case .threeQuarter: axis == .horizontal
            }
            let newAxis = rotation == .half ? axis : axis.flipped
            return swapChildren
                ? .split(axis: newAxis, ratio: 1 - ratio, first: walk(second), second: walk(first))
                : .split(axis: newAxis, ratio: ratio, first: walk(first), second: walk(second))
        }
        root = root.map(walk)
    }

    // MARK: - Recursion helpers

    /// Whether every window's minimum size fits `rect`. A window may come up to `gap` short: it then
    /// takes part of the gap beside it, which no other window uses, so nothing overlaps. 1 pt also
    /// absorbs rounding in split rects.
    static func fits(_ windows: [WindowID], in rect: CGRect, _ minimumSizes: MinimumSizes, gap: CGFloat = 0) -> Bool {
        let slack = max(gap, 1)
        return windows.allSatisfy { minimumSizes[$0].map { $0.width <= rect.width + slack && $0.height <= rect.height + slack } ?? true }
    }

    static func leaves(_ node: Node) -> [WindowID] {
        switch node {
        case .tile(let windows): windows
        case let .split(_, _, first, second): leaves(first) + leaves(second)
        }
    }

    private static func replacingTile(containing target: WindowID, in node: Node, with transform: ([WindowID]) -> Node) -> Node {
        switch node {
        case .tile(let windows):
            windows.contains(target) ? transform(windows) : node
        case let .split(axis, ratio, first, second):
            .split(axis: axis, ratio: ratio,
                   first: replacingTile(containing: target, in: first, with: transform),
                   second: replacingTile(containing: target, in: second, with: transform))
        }
    }

    private static func removing(_ window: WindowID, from node: Node) -> Node? {
        switch node {
        case .tile(let windows):
            let remaining = windows.filter { $0 != window }
            return remaining.isEmpty ? nil : .tile(remaining)
        case let .split(axis, ratio, first, second):
            switch (removing(window, from: first), removing(window, from: second)) {
            case let (a?, b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
    }

    static func mapTiles(_ node: Node, _ transform: ([WindowID]) -> [WindowID]) -> Node {
        switch node {
        case .tile(let windows): .tile(transform(windows))
        case let .split(axis, ratio, first, second):
            .split(axis: axis, ratio: ratio, first: mapTiles(first, transform), second: mapTiles(second, transform))
        }
    }

    /// Splits the backmost window out of the first stack that has room for it, or nil if none can.
    private static func unstackingOne(_ node: Node, rect: CGRect, gap: CGFloat, _ minimumSizes: MinimumSizes) -> Node? {
        switch node {
        case .tile(let windows):
            guard windows.count > 1 else { return nil }
            let axis: Axis = rect.width >= rect.height ? .horizontal : .vertical
            let (a, b) = rect.split(along: axis, ratio: 0.5, gap: gap)
            let kept = Array(windows.dropLast()), popped = [windows.last!]
            guard fits(kept, in: a, minimumSizes, gap: gap), fits(popped, in: b, minimumSizes, gap: gap) else { return nil }
            return .split(axis: axis, ratio: 0.5, first: .tile(kept), second: .tile(popped))
        case let .split(axis, ratio, first, second):
            let (a, b) = rect.split(along: axis, ratio: ratio, gap: gap)
            if let changed = unstackingOne(first, rect: a, gap: gap, minimumSizes) {
                return .split(axis: axis, ratio: ratio, first: changed, second: second)
            }
            return unstackingOne(second, rect: b, gap: gap, minimumSizes)
                .map { .split(axis: axis, ratio: ratio, first: first, second: $0) }
        }
    }

    /// The least length along `axis` a subtree needs to give every window its minimum size.
    private static func minimumLength(_ node: Node, along axis: Axis, gap: CGFloat, _ minimumSizes: MinimumSizes) -> CGFloat {
        switch node {
        case .tile(let windows):
            return windows.compactMap { minimumSizes[$0].map { axis == .horizontal ? $0.width : $0.height } }.max() ?? 0
        case let .split(nodeAxis, _, first, second):
            let a = minimumLength(first, along: axis, gap: gap, minimumSizes), b = minimumLength(second, along: axis, gap: gap, minimumSizes)
            return nodeAxis == axis ? a + gap + b : max(a, b)
        }
    }

    /// Moves each split's border, top down, into the range where both sides have room for their
    /// windows, when the split is long enough for both. Others keep their ratio, for merging.
    private static func fitting(_ node: Node, rect: CGRect, gap: CGFloat, _ minimumSizes: MinimumSizes) -> Node {
        guard case let .split(axis, ratio, first, second) = node else { return node }
        let available = rect.length(along: axis) - gap
        let needFirst = minimumLength(first, along: axis, gap: gap, minimumSizes)
        let needSecond = minimumLength(second, along: axis, gap: gap, minimumSizes)
        var fitted = ratio
        if available > 0, needFirst + needSecond <= available {
            fitted = min(max(ratio, Double(needFirst / available)), Double((available - needSecond) / available))
        }
        let (a, b) = rect.split(along: axis, ratio: fitted, gap: gap)
        return .split(axis: axis, ratio: fitted, first: fitting(first, rect: a, gap: gap, minimumSizes),
                      second: fitting(second, rect: b, gap: gap, minimumSizes))
    }

    /// Folds the first tile too small for its windows into the tile across its parent split, or nil if none overflow.
    private static func mergingOneOverflow(_ node: Node, rect: CGRect, gap: CGFloat, _ minimumSizes: MinimumSizes) -> Node? {
        guard case let .split(axis, ratio, first, second) = node else { return nil }
        let (a, b) = rect.split(along: axis, ratio: ratio, gap: gap)
        if case .tile(let windows) = first, !fits(windows, in: a, minimumSizes, gap: gap) {
            return appending(windows, toTileNearest: true, along: axis, in: second)
        }
        if case .tile(let windows) = second, !fits(windows, in: b, minimumSizes, gap: gap) {
            return appending(windows, toTileNearest: false, along: axis, in: first)
        }
        if let changed = mergingOneOverflow(first, rect: a, gap: gap, minimumSizes) {
            return .split(axis: axis, ratio: ratio, first: changed, second: second)
        }
        return mergingOneOverflow(second, rect: b, gap: gap, minimumSizes)
            .map { .split(axis: axis, ratio: ratio, first: first, second: $0) }
    }

    /// Adds `windows` to the back of the tile in `node` that bordered the removed tile.
    /// `leadingSide` means the removed tile sat before `node` along `axis`.
    private static func appending(_ windows: [WindowID], toTileNearest leadingSide: Bool, along axis: Axis, in node: Node) -> Node {
        switch node {
        case .tile(let existing):
            // A hole gives its place up rather than stacking
            return .tile(existing.allSatisfy(isHole) ? windows : existing + windows)
        case let .split(nodeAxis, ratio, first, second):
            // Across a same-axis split only one child touches the removed tile; otherwise both do
            let intoFirst = nodeAxis != axis || leadingSide
            return intoFirst
                ? .split(axis: nodeAxis, ratio: ratio, first: appending(windows, toTileNearest: leadingSide, along: axis, in: first), second: second)
                : .split(axis: nodeAxis, ratio: ratio, first: first, second: appending(windows, toTileNearest: leadingSide, along: axis, in: second))
        }
    }

    /// Applies `adjust` to the deepest split holding `window` that `matches` its axis and whether
    /// the window is in its first child.
    private static func adjustingNearestSplit(
        containing window: WindowID, in node: Node, rect: CGRect,
        where matches: (Axis, Bool) -> Bool, adjust: (Double, CGRect) -> Double
    ) -> Node {
        var adjusted = false
        func walk(_ node: Node, _ rect: CGRect) -> Node {
            guard case let .split(nodeAxis, ratio, first, second) = node else { return node }
            let (a, b) = rect.split(along: nodeAxis, ratio: ratio, gap: 0)
            let inFirst = leaves(first).contains(window)
            guard inFirst || leaves(second).contains(window) else { return node }
            let newFirst = inFirst ? walk(first, a) : first
            let newSecond = inFirst ? second : walk(second, b)
            guard !adjusted, matches(nodeAxis, inFirst) else {
                return .split(axis: nodeAxis, ratio: ratio, first: newFirst, second: newSecond)
            }
            adjusted = true
            let newRatio = adjust(ratio, rect).clamped(to: ratioRange)
            return .split(axis: nodeAxis, ratio: newRatio, first: newFirst, second: newSecond)
        }
        return walk(node, rect)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
