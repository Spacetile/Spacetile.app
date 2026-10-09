import CoreGraphics

/// How Tile mode places windows. Every algorithm keeps the one tree, so swapping, dragging,
/// resizing, profiles and full screen work the same in each; they differ in where a new window goes
/// and how the others close up when one leaves.
public enum TileAlgorithm: String, Codable, CaseIterable, Sendable {
    /// A new window splits the focused window's tile in two (yabai).
    case bsp
    /// A new window joins the focused window's row or column, just after it, and the row shares its
    /// length out between them all. A window leaving gives its share back to the whole row. i3's split
    /// containers, which Sway and AeroSpace follow.
    case i3
    /// One main window keeps the split ratio of the Space; the others share the rest in a column
    /// beside it, newest last (Amethyst Tall, dwm).
    case masterStack = "master-stack"
}

/// How Stack mode lays windows out.
public enum StackAlgorithm: String, Codable, CaseIterable, Sendable {
    /// Every window fills the whole tile area.
    case fill
    /// The front window fills the tile area but for a strip at each side, where the windows before
    /// and after it in the stack show (AeroSpace's accordion).
    case accordion
}

extension TileAlgorithm {
    public var name: String {
        switch self {
        case .bsp: "BSP"
        case .i3: "i3 (rows and columns)"
        case .masterStack: "Master and stack"
        }
    }

    public var detail: String {
        switch self {
        case .bsp: "A new window splits the focused window's tile in two."
        case .i3: "A new window joins the focused window's row or column, and the row shares its space out evenly, as in i3 and AeroSpace."
        case .masterStack: "One main window keeps the split ratio; the rest share a column beside it."
        }
    }
}

extension StackAlgorithm {
    public var name: String {
        switch self {
        case .fill: "Fill"
        case .accordion: "Accordion"
        }
    }

    public var detail: String {
        switch self {
        case .fill: "Every window fills the Space."
        case .accordion: "The front window leaves a strip at each side where the windows before and after it peek out."
        }
    }
}

// MARK: - i3

/// i3's tree is n-ary: a split container lays out any number of children along one axis. Here a
/// container is a run of same-axis splits, and its children are the tiles and other-axis splits
/// directly under that run. Splitting the run differently changes nothing on screen, so only each
/// child's share of the run matters. A row can't sit directly in a row, so nested same-axis
/// containers merge, as AeroSpace's normalization makes them.
extension BSPTree {
    /// The children of the container `node` heads, each with its share of the container's length.
    static func members(_ node: Node, along axis: Axis) -> [(node: Node, share: Double)] {
        guard case let .split(nodeAxis, ratio, first, second) = node, nodeAxis == axis else { return [(node, 1)] }
        return members(first, along: axis).map { ($0.node, $0.share * ratio) }
            + members(second, along: axis).map { ($0.node, $0.share * (1 - ratio)) }
    }

    /// A container of `members` along `axis`, each taking its share of the total.
    static func container(_ members: [(node: Node, share: Double)], along axis: Axis) -> Node {
        guard members.count > 1 else { return members[0].node }
        let total = members.reduce(0) { $0 + $1.share }
        return .split(axis: axis, ratio: members[0].share / total, first: members[0].node,
                      second: container(Array(members.dropFirst()), along: axis))
    }

    /// Rebuilds the container that directly holds `window`'s tile with `transform(axis, members,
    /// index of the tile)`. Nil when the window's tile is the whole tree, so there's no container.
    static func rewritingContainer(
        of window: WindowID, in node: Node,
        _ transform: (Axis, [(node: Node, share: Double)], Int) -> Node
    ) -> Node? {
        guard case let .split(axis, _, _, _) = node, leaves(node).contains(window) else { return nil }
        let members = members(node, along: axis)
        if let index = members.firstIndex(where: { if case .tile(let windows) = $0.node { windows.contains(window) } else { false } }) {
            return transform(axis, members, index)
        }
        // Down through this container to the child holding the window, leaving the rest as it is
        func descend(_ node: Node) -> Node {
            guard case let .split(nodeAxis, ratio, first, second) = node, nodeAxis == axis else {
                return rewritingContainer(of: window, in: node, transform) ?? node
            }
            return leaves(first).contains(window)
                ? .split(axis: nodeAxis, ratio: ratio, first: descend(first), second: second)
                : .split(axis: nodeAxis, ratio: ratio, first: first, second: descend(second))
        }
        return descend(node)
    }

    /// Puts `window` in the container holding `target`'s tile (or the last window's), just after it.
    /// It takes an average share, which the others give up in proportion to their own. A lone tile
    /// becomes a container along the longer side of `bounds`.
    public mutating func insertJoining(_ window: WindowID, beside target: WindowID?, in bounds: CGRect) {
        guard let root, !contains(window) else {
            if self.root == nil { self.root = .leaf(window) }
            return
        }
        // Only holes: they're BSP shapes from a profile, which BSP insertion knows how to fill
        guard let anchor = target.flatMap({ contains($0) ? $0 : nil }) ?? windows.last else {
            return insert(window, beside: nil, in: bounds)
        }
        guard let rewritten = Self.rewritingContainer(of: anchor, in: root, { axis, members, index in
            var members = members
            members.insert((.leaf(window), 1 / Double(members.count)), at: index + 1)
            return Self.container(members, along: axis)
        }) else {
            self.root = .split(axis: bounds.width >= bounds.height ? .horizontal : .vertical, ratio: 0.5, first: root, second: .leaf(window))
            return
        }
        self.root = rewritten
    }

    /// Removes `window`. Leaving a stack, the stack's tile stays; otherwise the rest of its container
    /// shares out its space in proportion to what each already has.
    public mutating func removeFromContainer(_ window: WindowID) {
        guard let root, contains(window), stack(containing: window).count == 1,
              let rewritten = Self.rewritingContainer(of: window, in: root, { axis, members, index in
                  var members = members
                  members.remove(at: index)
                  return Self.container(members, along: axis)
              }) else { return remove(window) }
        self.root = rewritten
    }

    /// Turns the container holding `window`'s tile from a row into a column or back, keeping each
    /// child's share (i3's `layout toggle split`).
    public mutating func toggleContainer(of window: WindowID) {
        guard let root, let rewritten = Self.rewritingContainer(of: window, in: root, { axis, members, _ in
            Self.container(members, along: axis.flipped)
        }) else { return }
        self.root = rewritten
    }
}

// MARK: - Master and stack

extension BSPTree {
    /// Where the main tile sits and how much it takes: what a master-stack layout keeps as windows
    /// come and go.
    public struct MainShape: Equatable, Sendable {
        /// `horizontal` puts the stack beside the main tile; `vertical` puts it below or above.
        public var axis: Axis
        /// The main tile is on the leading side (left or top).
        public var mainFirst: Bool
        /// The main tile's share of the Space.
        public var share: Double
    }

    /// The shape the tree has now: its top split's axis, with the main tile on the side holding a
    /// single tile when only one side does, and that side's share. `share` when there is no split.
    public func mainShape(defaultShare share: Double) -> MainShape {
        guard case let .split(axis, ratio, first, second) = root else { return MainShape(axis: .horizontal, mainFirst: true, share: share) }
        var mainFirst = true
        if case .split = first, case .tile = second { mainFirst = false }
        return MainShape(axis: axis, mainFirst: mainFirst, share: mainFirst ? ratio : 1 - ratio)
    }

    /// Rebuilds the tree in `shape`: the main tile (the first tile on the main side) and the other
    /// tiles in order, sharing the rest equally, with `adding` at the end. Stacks stay stacked.
    public mutating func arrangeMain(_ shape: MainShape, adding window: WindowID? = nil) {
        var tiles = tiles(in: .zero, gap: 0).map(\.windows)
        guard !tiles.isEmpty else {
            root = window.map(Node.leaf)
            return
        }
        // Mirrored, the main tile comes last in tree order
        let main = shape.mainFirst ? tiles.removeFirst() : tiles.removeLast()
        if let window, !contains(window) { tiles.append([window]) }
        guard !tiles.isEmpty else {
            root = .tile(main)
            return
        }
        let stack = Self.container(tiles.map { (.tile($0), 1) }, along: shape.axis.flipped)
        root = .split(axis: shape.axis, ratio: shape.mainFirst ? shape.share : 1 - shape.share,
                      first: shape.mainFirst ? .tile(main) : stack, second: shape.mainFirst ? stack : .tile(main))
    }
}
