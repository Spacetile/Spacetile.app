import CoreGraphics

/// What macOS's own window tiling (the green button's Move & Resize and Fill & Arrange, the Window
/// menu, fn⌃ arrows) did to a window, read back from its frame. Nothing in Accessibility says a
/// window is tiled, so frames are all there is to go on.
public enum NativeTile: Equatable, Sendable {
    /// A half or a quarter of the display, as `place` takes it.
    case region(Region)
    /// The whole visible frame: Fill.
    case fill
}

public enum NativeTiling {
    /// How far, as a share of the display, a frame can be from a native tile and still count. Wide
    /// enough for macOS's tile margins (a few points round each tile), narrow enough that a window
    /// dragged by hand rarely lands inside it.
    public static let tolerance = 0.03

    /// The native tile `frame` is, within `visible` (the display's visible frame, below the menu bar
    /// and beside the Dock, in the same coordinates), or nil for any other frame.
    public static func classify(_ frame: CGRect, in visible: CGRect, tolerance: Double = tolerance) -> NativeTile? {
        guard visible.width > 0, visible.height > 0 else { return nil }
        let left = (frame.minX - visible.minX) / visible.width, right = (frame.maxX - visible.minX) / visible.width
        let top = (frame.minY - visible.minY) / visible.height, bottom = (frame.maxY - visible.minY) / visible.height
        func near(_ value: Double, _ target: Double) -> Bool { abs(value - target) <= tolerance }
        // Which part of each axis the frame covers: all of it, or its leading or trailing half
        enum Part { case whole, leading, trailing }
        func part(_ start: Double, _ end: Double) -> Part? {
            if near(start, 0), near(end, 1) { return .whole }
            if near(start, 0), near(end, 0.5) { return .leading }
            if near(start, 0.5), near(end, 1) { return .trailing }
            return nil
        }
        guard let horizontal = part(left, right), let vertical = part(top, bottom) else { return nil }
        let column: Direction = horizontal == .leading ? .west : .east, row: Direction = vertical == .leading ? .north : .south
        switch (horizontal, vertical) {
        case (.whole, .whole): return .fill
        case (_, .whole): return .region(.edge(column, fraction: 0.5))
        case (.whole, _): return .region(.edge(row, fraction: 0.5))
        default: return .region(.corner(vertical: row, horizontal: column))
        }
    }

    /// The tree whose tiles are `frames`, found by cutting them apart along full-length gaps (a
    /// guillotine cut), side by side before stacked. Every Fill & Arrange layout cuts this way.
    /// Frames lying almost on top of each other share a tile, as a stack. Nil when the frames
    /// can't be cut apart, or when there are none.
    public static func tree(from frames: [WindowID: CGRect], tolerance: CGFloat = 12) -> BSPTree? {
        guard !frames.isEmpty else { return nil }
        let items = frames.map { (id: $0.key, rect: $0.value) }.sorted { ($0.rect.minY, $0.rect.minX, $0.id) < ($1.rect.minY, $1.rect.minX, $1.id) }
        return node(items, tolerance: tolerance).map { BSPTree(root: $0) }
    }

    private static func node(_ items: [(id: WindowID, rect: CGRect)], tolerance: CGFloat) -> Node? {
        if items.count == 1 { return .leaf(items[0].id) }
        let bounds = items.reduce(CGRect.null) { $0.union($1.rect) }
        for axis in [Axis.horizontal, .vertical] {
            guard let (first, second, cut) = split(items, along: axis, tolerance: tolerance),
                  let a = node(first, tolerance: tolerance), let b = node(second, tolerance: tolerance) else { continue }
            let start = axis == .horizontal ? bounds.minX : bounds.minY
            let length = axis == .horizontal ? bounds.width : bounds.height
            let ratio = length > 0 ? Double((cut - start) / length) : 0.5
            // Gaps and rounding leave a half a hair off; the shares macOS uses come back exact
            let snapped = [0.5, 1.0 / 3, 2.0 / 3, 0.25, 0.75].first { abs($0 - ratio) < 0.01 } ?? ratio
            return .split(axis: axis, ratio: snapped.clamped(to: BSPTree.ratioRange), first: a, second: b)
        }
        // No cut, but every frame nearly the same: one stack, front first as given
        let first = items[0].rect
        let same = items.allSatisfy {
            abs($0.rect.minX - first.minX) <= tolerance && abs($0.rect.minY - first.minY) <= tolerance
                && abs($0.rect.maxX - first.maxX) <= tolerance && abs($0.rect.maxY - first.maxY) <= tolerance
        }
        return same ? .tile(items.map(\.id)) : nil
    }

    /// The first line along `axis` with every frame wholly before or after it (frames may overlap
    /// it by `tolerance`) and some on each side. Returns both sides and the cut position, midway
    /// across the gap.
    private static func split(_ items: [(id: WindowID, rect: CGRect)], along axis: Axis, tolerance: CGFloat)
        -> ([(id: WindowID, rect: CGRect)], [(id: WindowID, rect: CGRect)], CGFloat)? {
        let start = { (rect: CGRect) in axis == .horizontal ? rect.minX : rect.minY }
        let end = { (rect: CGRect) in axis == .horizontal ? rect.maxX : rect.maxY }
        // Candidate cuts sit at each frame's far edge
        for edge in Set(items.map { end($0.rect) }).sorted() {
            let before = items.filter { end($0.rect) <= edge + tolerance }
            let after = items.filter { start($0.rect) >= edge - tolerance }
            guard !before.isEmpty, !after.isEmpty, before.count + after.count == items.count,
                  Set(before.map(\.id)).isDisjoint(with: after.map(\.id)) else { continue }
            let gapEnd = after.map { start($0.rect) }.min() ?? edge
            return (before, after, (edge + max(gapEnd, edge)) / 2)
        }
        return nil
    }

    /// Whether `frames` together cover most of `visible`, as an arrangement does. Windows macOS
    /// moved for another reason (an app restoring its own frame) seldom do.
    public static func covers(_ frames: [CGRect], _ visible: CGRect, share: Double = 0.85) -> Bool {
        guard visible.width > 0, visible.height > 0 else { return false }
        let area = frames.reduce(0.0) { total, frame in
            let inside = frame.intersection(visible)
            return total + (inside.isNull ? 0 : Double(inside.width * inside.height))
        }
        return area >= share * Double(visible.width * visible.height)
    }
}

extension SpaceLayout {
    /// Takes the shape macOS arranged some of this Space's windows in (Fill & Arrange). Tiled
    /// windows `arranged` leaves out stack behind its last tile, as they sit behind the arrangement
    /// on screen. Floating windows that macOS arranged join the tiling. Joins the current run of
    /// sizing commands, so `restore` undoes it.
    public mutating func adopt(_ arranged: BSPTree) {
        guard mode == .bsp, let root = arranged.root else { return }
        let before = tree
        let placed = Set(arranged.windows)
        let rest = tree.windows.filter { !placed.contains($0) }
        floating.subtract(placed)
        zoomed = nil
        preselection = nil
        func appending(_ node: Node) -> Node {
            switch node {
            case .tile(let windows): .tile(windows + rest)
            case let .split(axis, ratio, first, second): .split(axis: axis, ratio: ratio, first: first, second: appending(second))
            }
        }
        tree = BSPTree(root: rest.isEmpty ? root : appending(root))
        waiting = [:]
        if tree != before { previousTree = previousTree ?? before }
    }

    /// Takes the shape macOS arranged some of this Space's windows in when together they fill one
    /// half of the display (two windows tiled into the bottom quarters, say). The Space's other
    /// windows keep their tiling in the other half, or a hole stands in when there are none, as
    /// `place` leaves one. Joins the current run of sizing commands, so `restore` undoes it.
    public mutating func adopt(_ arranged: BSPTree, inHalf edge: Direction) {
        guard mode == .bsp, let root = arranged.root else { return }
        let before = tree
        var rest = tree
        rest.removeHoles()
        for window in arranged.windows { rest.remove(window) }
        floating.subtract(arranged.windows)
        zoomed = nil
        preselection = nil
        let other = rest.root ?? hole()
        tree = BSPTree(root: .split(axis: edge.axis, ratio: 0.5, first: edge.isLeading ? root : other, second: edge.isLeading ? other : root))
        waiting = [:]
        if tree != before { previousTree = previousTree ?? before }
    }

    /// Fills the tile area with `window`, as zoom does, without toggling it off when it already is.
    public mutating func zoom(_ window: WindowID) {
        guard tree.contains(window) else { return }
        zoomed = window
    }
}
