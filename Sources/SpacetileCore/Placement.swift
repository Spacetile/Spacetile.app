import CoreGraphics

/// Where `place` puts a window: Raycast-style regions of the Space.
public enum Region: Equatable, Sendable {
    /// A full-height column or full-width row on an edge. A nil fraction cycles ½ → ⅔ → ⅓.
    case edge(Direction, fraction: Double?)
    /// A quarter: `vertical` is north or south, `horizontal` west or east.
    case corner(vertical: Direction, horizontal: Direction)
    /// The middle column of three.
    case center
    /// One cell of a three-column, two-row grid: `column` 0…2, `row` 0…1.
    case sixth(column: Int, row: Int)
    /// A full-height column over `span`, as fractions of the Space's width: maximize height. Nil is
    /// wherever the window is now, which the window manager fills in from its frame.
    case column(span: ClosedRange<Double>?)

    /// The fractions repeating an edge steps through.
    public static let cycle = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// Where the region lies in `bounds`, as a floating window would take it.
    public func rect(in bounds: CGRect, gap: CGFloat, fraction: Double = 0.5) -> CGRect {
        switch self {
        case let .edge(edge, explicit):
            let share = explicit ?? fraction
            let (a, b) = bounds.split(along: edge.axis, ratio: edge.isLeading ? share : 1 - share, gap: gap)
            return edge.isLeading ? a : b
        case let .corner(vertical, horizontal):
            let (left, right) = bounds.split(along: .horizontal, ratio: 0.5, gap: gap)
            let (top, bottom) = (horizontal == .west ? left : right).split(along: .vertical, ratio: 0.5, gap: gap)
            return vertical == .north ? top : bottom
        case .center:
            return Self.columns(bounds, gap: gap)[1]
        case let .sixth(column, row):
            let (top, bottom) = Self.columns(bounds, gap: gap)[column].split(along: .vertical, ratio: 0.5, gap: gap)
            return row == 0 ? top : bottom
        case let .column(span):
            let span = span ?? 0...1
            return CGRect(x: bounds.minX + bounds.width * span.lowerBound, y: bounds.minY,
                          width: bounds.width * (span.upperBound - span.lowerBound), height: bounds.height)
        }
    }

    /// The share of `bounds`' width that `frame` covers, as `column` takes it.
    public static func span(of frame: CGRect, in bounds: CGRect) -> ClosedRange<Double> {
        let start = min(max((frame.minX - bounds.minX) / bounds.width, 0), 1)
        let end = min(max((frame.maxX - bounds.minX) / bounds.width, start), 1)
        return start...end
    }

    private static func columns(_ bounds: CGRect, gap: CGFloat) -> [CGRect] {
        let (left, rest) = bounds.split(along: .horizontal, ratio: 1.0 / 3, gap: gap)
        let (center, right) = rest.split(along: .horizontal, ratio: 0.5, gap: gap)
        return [left, center, right]
    }
}

extension SpaceLayout {
    /// Gives `window` a region of the Space; the other windows re-tile in what's left. Where there
    /// aren't enough windows to fill the region's shape, holes stand in for them. The layout before
    /// a run of sizing commands is kept for `restore`.
    public mutating func place(_ window: WindowID, in region: Region, bounds: CGRect) {
        guard mode == .bsp, tree.contains(window) else { return }
        let before = tree
        zoomed = nil
        preselection = nil
        // A placement starts afresh: earlier holes and the window's old tile go
        var rest = tree
        rest.removeHoles()
        rest.remove(window)

        switch region {
        case let .edge(edge, explicit):
            let share = explicit ?? nextCycleShare(of: window, edge: edge)
            let other = rest.root ?? hole()
            tree = BSPTree(root: .split(axis: edge.axis, ratio: edge.isLeading ? share : 1 - share,
                                        first: edge.isLeading ? .leaf(window) : other,
                                        second: edge.isLeading ? other : .leaf(window)))

        case let .corner(vertical, horizontal):
            // The window shares its edge column with the neighbour below (or above) it, or with a
            // hole, so the other windows keep the far side to themselves
            let partner = neighbor(of: window, toward: vertical == .north ? .south : .north, in: bounds)
            if let partner { rest.remove(partner) }
            let partnerNode = partner.map(Node.leaf) ?? hole()
            let column = Node.split(axis: .vertical, ratio: 0.5,
                                    first: vertical == .north ? .leaf(window) : partnerNode,
                                    second: vertical == .north ? partnerNode : .leaf(window))
            let other = rest.root ?? hole()
            tree = BSPTree(root: .split(axis: .horizontal, ratio: 0.5,
                                        first: horizontal == .west ? column : other,
                                        second: horizontal == .west ? other : column))

        case .center:
            // The other windows split into a column either side, in tree order
            let others = rest.windows
            let left = Array(others.prefix((others.count + 1) / 2)), right = Array(others.dropFirst(left.count))
            tree = BSPTree(root: .split(axis: .horizontal, ratio: 1.0 / 3, first: column(of: left),
                                        second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(window), second: column(of: right))))

        case let .sixth(targetColumn, targetRow):
            // The other windows fill the remaining cells in tree order; extras stack in the last one
            var cells = Array(repeating: [WindowID](), count: 6)
            let target = targetColumn * 2 + targetRow
            cells[target] = [window]
            let free = (0..<6).filter { $0 != target }
            for (index, other) in rest.windows.enumerated() { cells[free[min(index, free.count - 1)]].append(other) }
            let nodes = cells.map { $0.isEmpty ? hole() : .tile($0) }
            let columns = (0..<3).map { Node.split(axis: .vertical, ratio: 0.5, first: nodes[$0 * 2], second: nodes[$0 * 2 + 1]) }
            tree = BSPTree(root: .split(axis: .horizontal, ratio: 1.0 / 3, first: columns[0],
                                        second: .split(axis: .horizontal, ratio: 0.5, first: columns[1], second: columns[2])))

        case let .column(span):
            // Snapped to an edge it's that edge's column, so the other windows keep their arrangement
            let span = span ?? 0...1, snap = 0.02
            let (start, end) = (span.lowerBound < snap ? 0 : span.lowerBound, span.upperBound > 1 - snap ? 1 : span.upperBound)
            guard end - start < 1 - snap, end > start else { tree = before; return }
            if start == 0 || end == 1 {
                let other = rest.root ?? hole()
                tree = BSPTree(root: .split(axis: .horizontal, ratio: start == 0 ? end : start,
                                            first: start == 0 ? .leaf(window) : other, second: start == 0 ? other : .leaf(window)))
            } else {
                // In the middle: the others form a column either side, by which side of it they sit
                let frames = frames(in: bounds, gap: 0), middle = bounds.minX + bounds.width * (start + end) / 2
                let left = rest.windows.filter { (frames[$0]?.midX ?? 0) < middle }, right = rest.windows.filter { !left.contains($0) }
                tree = BSPTree(root: .split(axis: .horizontal, ratio: start, first: column(of: left),
                                            second: .split(axis: .horizontal, ratio: (end - start) / (1 - start),
                                                           first: .leaf(window), second: column(of: right))))
            }
        }
        previousTree = previousTree ?? before
    }

    /// Moves every inner border of the window's tile outwards (`grow`) or inwards by a tenth of the Space,
    /// or as much of that as leaves every window its minimum size: a border never squeezes a
    /// neighbour into a stack. Joins the current run of sizing commands for `restore`.
    public mutating func resize(_ window: WindowID, grow: Bool, in bounds: CGRect, gap: CGFloat = 0, minimumSizes: MinimumSizes = [:]) {
        guard mode == .bsp, tree.contains(window) else { return }
        let before = tree
        let overflowed = tree.overflows(in: bounds, gap: gap, minimumSizes: minimumSizes)
        for edge in Direction.allCases {
            let step = bounds.length(along: edge.axis) / 10
            let outwards = edge.isLeading ? -step : step
            for share in [1.0, 0.5, 0.25] {
                var moved = tree
                moved.moveEdge(edge, of: window, by: (grow ? outwards : -outwards) * share, in: bounds)
                if overflowed || !moved.overflows(in: bounds, gap: gap, minimumSizes: minimumSizes) {
                    tree = moved
                    break
                }
            }
        }
        if tree != before { previousTree = previousTree ?? before }
    }

    /// Undoes a run of place, grow and shrink commands, back to the layout before the first of them.
    /// Windows closed since are left out and windows opened since are added back as usual.
    public mutating func restore(in bounds: CGRect) {
        guard var restored = previousTree else { return }
        let current = Set(tree.windows)
        for window in restored.windows where !current.contains(window) { restored.remove(window) }
        for window in tree.windows where !restored.contains(window) { restored.insert(window, beside: nil, in: bounds) }
        tree = restored
        previousTree = nil
        zoomed = nil
    }

    /// The share the window gets when its edge is pressed again: the next step in the cycle if it
    /// already sits on that edge at a cycle size, otherwise a half.
    private func nextCycleShare(of window: WindowID, edge: Direction) -> Double {
        guard case let .split(axis, ratio, first, second)? = tree.root, axis == edge.axis,
              (edge.isLeading ? first : second) == .leaf(window) else { return Region.cycle[0] }
        let share = edge.isLeading ? ratio : 1 - ratio
        guard let index = Region.cycle.firstIndex(where: { abs($0 - share) < 0.02 }) else { return Region.cycle[0] }
        return Region.cycle[(index + 1) % Region.cycle.count]
    }

    mutating func hole() -> Node {
        defer { nextHole += 1 }
        return .leaf(nextHole)
    }

    /// Windows stacked top to bottom in equal rows, or a hole when there are none.
    private mutating func column(of windows: [WindowID]) -> Node {
        guard let first = windows.first else { return hole() }
        guard windows.count > 1 else { return .leaf(first) }
        let rest = Array(windows.dropFirst())
        return .split(axis: .vertical, ratio: 1 / Double(windows.count), first: .leaf(first), second: column(of: rest))
    }
}

extension SpaceLayout {
    /// Ends a run of sizing commands: any other change to the layout makes it the new baseline.
    public mutating func endSizingRun() { previousTree = nil }
}
