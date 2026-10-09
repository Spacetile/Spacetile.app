import CoreGraphics

/// What dropping a dragged tiled window onto a tile does.
public enum DropAction: Equatable, Sendable {
    /// Dropped in the middle of another tile: the two windows trade places.
    case swap(with: WindowID)
    /// Dropped near an edge: the window moves next to the tile, on that side.
    case insert(beside: WindowID, side: Direction)
}

public enum LayoutMode: String, Codable, Sendable {
    /// Binary space partition tiling.
    case bsp
    /// Every tiled window fills the whole tile area; focus keys cycle through them.
    case stack
    /// Nothing is positioned; windows stay where the user puts them.
    case float
}

extension LayoutMode {
    /// The one SF Symbol for each mode, wherever Spacetile shows it: menu bar, pickers, Keys.
    public var symbol: String {
        switch self {
        case .bsp: "rectangle.split.2x1"
        case .stack: "square.stack"
        case .float: "macwindow.on.rectangle"
        }
    }
}

/// Tiling state for one Space.
public struct SpaceLayout: Equatable, Sendable {
    public var mode: LayoutMode
    /// How Tile mode places windows. Setting it keeps the tree as it is (a profile's shape, say), so
    /// only where windows go from now on changes; `setTiling` also reshapes it for master and stack.
    public var tiling = TileAlgorithm.bsp
    /// How Stack mode lays windows out.
    public var stacking = StackAlgorithm.fill
    public internal(set) var tree = BSPTree()
    /// Managed windows the user (or a rule) has taken out of the tree.
    public internal(set) var floating: Set<WindowID> = []
    /// A tiled window temporarily filling the whole tile area.
    public internal(set) var zoomed: WindowID?
    /// Where the next window goes: beside `window`, on the `direction` side (yabai preselect).
    public internal(set) var preselection: Preselection?

    /// The tree before the last place, grow or shrink, for `restore`.
    public internal(set) var previousTree: BSPTree?
    /// The ID the next hole will take.
    var nextHole = BSPTree.firstHole
    /// Holes from a profile still waiting for a window, by the bundle ID of the app they're for.
    /// Only that app's windows fill them.
    public internal(set) var waiting: [WindowID: String] = [:]
    /// The tiled window focused last, which an accordion stack puts in front.
    public internal(set) var front: WindowID?
    /// The last pop out, for pop in to exchange back.
    public internal(set) var popped: Pop?

    /// `window` popped out into `displaced`'s tile.
    public struct Pop: Equatable, Sendable {
        public let window: WindowID
        public let displaced: WindowID
    }

    public struct Preselection: Equatable, Sendable {
        public let window: WindowID
        public let direction: Direction
    }

    public init(mode: LayoutMode = .bsp, tiling: TileAlgorithm = .bsp, stacking: StackAlgorithm = .fill) {
        self.mode = mode
        self.tiling = tiling
        self.stacking = stacking
    }

    /// The width of the strip where windows behind an accordion's front window show.
    public static let accordionPadding: CGFloat = 30

    /// Changes how new windows are tiled. Master and stack reshapes the tree straight away,
    /// keeping the main tile's share when the tree already has a main tile; `share` otherwise.
    public mutating func setTiling(_ algorithm: TileAlgorithm, share: Double = 0.5) {
        guard algorithm != tiling else { return }
        tiling = algorithm
        if algorithm == .masterStack {
            zoomed = nil
            tree.arrangeMain(tree.mainShape(defaultShare: share))
        }
    }

    public func contains(_ window: WindowID) -> Bool { tree.contains(window) || floating.contains(window) }

    /// Adds a window: to the preselected spot if there is one, else into the first hole, else
    /// splitting `target`'s tile with the existing window keeping `ratio` of it.
    public mutating func add(
        _ window: WindowID, app: String? = nil, beside target: WindowID?, in bounds: CGRect, gap: CGFloat = 0,
        floating isFloating: Bool = false, ratio: Double = 0.5, minimumSizes: MinimumSizes = [:]
    ) {
        guard !contains(window) else { return }
        // A profile kept a tile for this app: the window goes there, whatever else is set
        if let app, let hole = waiting.filter({ $0.value == app }).keys.min() {
            tree.replace(hole, with: window)
            waiting[hole] = nil
            return
        }
        if isFloating {
            floating.insert(window)
            return
        }
        zoomed = nil
        if let preselection, tree.contains(preselection.window) {
            tree.insert(window, beside: preselection.window, in: bounds, gap: gap, preselect: preselection.direction,
                        ratio: ratio, minimumSizes: minimumSizes)
            self.preselection = nil
        } else if let hole = tree.holes.first(where: { waiting[$0] == nil }) {
            tree.replace(hole, with: window)
        } else {
            insertTiled(window, beside: target, in: bounds, gap: gap, ratio: ratio, minimumSizes: minimumSizes)
        }
    }

    /// Tiles `window` the way the tiling algorithm says.
    private mutating func insertTiled(
        _ window: WindowID, beside target: WindowID?, in bounds: CGRect, gap: CGFloat,
        ratio: Double, minimumSizes: MinimumSizes
    ) {
        switch tiling {
        case .bsp:
            tree.insert(window, beside: target, in: bounds, gap: gap, ratio: ratio, minimumSizes: minimumSizes,
                        keeping: Set(waiting.keys))
        case .i3:
            tree.insertJoining(window, beside: target, in: bounds)
        case .masterStack:
            tree.arrangeMain(tree.mainShape(defaultShare: ratio), adding: window)
        }
    }

    /// Takes `window` out of the tree the way the tiling algorithm closes up after it.
    private mutating func removeTiled(_ window: WindowID) {
        switch tiling {
        case .bsp:
            tree.remove(window)
        case .i3:
            tree.removeFromContainer(window)
        case .masterStack:
            let shape = tree.mainShape(defaultShare: 0.5)
            tree.remove(window)
            tree.arrangeMain(shape)
        }
    }

    /// Sets where the next window goes; choosing the same direction again cancels it.
    public mutating func preselect(_ direction: Direction, beside window: WindowID) {
        guard tree.contains(window) else { return }
        let choice = Preselection(window: window, direction: direction)
        preselection = preselection == choice ? nil : choice
    }

    /// The half of the preselected window's tile the next window will take, for the overlay.
    public func preselectionRect(in bounds: CGRect, gap: CGFloat) -> CGRect? {
        guard let preselection, let tile = tree.frames(in: bounds, gap: gap)[preselection.window] else { return nil }
        let halves = tile.split(along: preselection.direction.axis, ratio: 0.5, gap: gap)
        return preselection.direction.isLeading ? halves.0 : halves.1
    }

    /// Puts `window` and its neighbour in `direction` together in the neighbour's tile, split the
    /// other way: side by side they end up one above the other, stacked they end up side by side.
    /// Their order stays, as AeroSpace's `join-with` does.
    public mutating func join(_ window: WindowID, toward direction: Direction, in bounds: CGRect, gap: CGFloat) {
        guard let other = neighbor(of: window, toward: direction, in: bounds) else { return }
        let first = direction == .east || direction == .south
        let side: Direction = switch direction.axis {
        case .horizontal: first ? .north : .south
        case .vertical: first ? .west : .east
        }
        perform(.insert(beside: other, side: side), dragging: window, in: bounds, gap: gap)
    }

    /// Flips the focused window's split between side by side and stacked. With i3 tiling the
    /// whole row or column it's in turns.
    public mutating func toggleSplit(of window: WindowID) {
        if tiling == .i3 { tree.toggleContainer(of: window) } else { tree.toggleSplit(ofParentOf: window) }
    }

    /// Records focus so the window fronts its stack and is the one neighbours lead back to.
    public mutating func focus(_ window: WindowID) {
        tree.bringToFront(window)
        front = window
    }

    /// Unstacks where there's room and stacks tiles too small for their windows.
    public mutating func normalize(in bounds: CGRect, gap: CGFloat, minimumSizes: MinimumSizes) {
        guard mode == .bsp else { return }
        tree.normalize(in: bounds, gap: gap, minimumSizes: minimumSizes)
    }

    /// The next (or previous) window in `window`'s stack, wrapping. In stack mode the whole Space is one stack.
    public func cycle(from window: WindowID, forward: Bool) -> WindowID? {
        let stack = mode == .stack ? tree.windows : tree.stack(containing: window)
        guard let index = stack.firstIndex(of: window), stack.count > 1 else { return nil }
        return stack[(index + (forward ? 1 : -1) + stack.count) % stack.count]
    }

    /// Windows hidden behind another in a stack: what the menu bar counts.
    public var stackedOutOfSight: Int {
        switch mode {
        case .float: 0
        case .stack: max(tree.windows.count - 1, 0)
        case .bsp: tree.tiles(in: .zero, gap: 0).reduce(0) { $0 + $1.windows.count - 1 }
        }
    }

    /// Where a window sits on this Space, to put it back later with `reinsert`.
    public enum Slot: Equatable, Sendable {
        case floating
        case tiled(BSPTree.Slot)
    }

    public func slot(of window: WindowID) -> Slot? {
        floating.contains(window) ? .floating : tree.slot(of: window).map(Slot.tiled)
    }

    /// Puts a window back where it was. Returns false when its old neighbours are gone, for the
    /// caller to `add` it as new instead.
    public mutating func reinsert(_ window: WindowID, at slot: Slot) -> Bool {
        guard !contains(window) else { return false }
        switch slot {
        case .floating:
            floating.insert(window)
            return true
        case .tiled(let slot):
            guard tree.reinsert(window, at: slot) else { return false }
            zoomed = nil
            return true
        }
    }

    /// Puts `new` in `old`'s place, tiled or floating, closing up its own: a window tab taking over
    /// from the tab it was selected over.
    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard old != new, contains(old) else { return }
        tree.remove(new)
        floating.remove(new)
        tree.replace(old, with: new)
        if floating.remove(old) != nil { floating.insert(new) }
        if zoomed == old { zoomed = new }
        if preselection?.window == old { preselection = nil }
        if let pop = popped {
            popped = Pop(window: pop.window == old ? new : pop.window, displaced: pop.displaced == old ? new : pop.displaced)
        }
    }

    /// Removes a window. Holes go with it: they only hold a placement's shape while it stands.
    public mutating func remove(_ window: WindowID) {
        if preselection?.window == window { preselection = nil }
        if front == window { front = nil }
        forgetPop(of: window)
        // Holes aren't windows, so they always just go
        if tree.contains(window) { removeTiled(window) } else { tree.remove(window) }
        tree.removeHoles()
        waiting = [:]
        floating.remove(window)
        if zoomed == window { zoomed = nil }
    }

    public mutating func toggleFloat(_ window: WindowID, beside target: WindowID?, in bounds: CGRect) {
        if floating.remove(window) != nil {
            insertTiled(window, beside: target, in: bounds, gap: 0, ratio: 0.5, minimumSizes: [:])
        } else if tree.contains(window) {
            removeTiled(window)
            floating.insert(window)
            if zoomed == window { zoomed = nil }
            forgetPop(of: window)
        }
    }

    public mutating func toggleZoom(_ window: WindowID) {
        guard tree.contains(window) else { return }
        zoomed = zoomed == window ? nil : window
    }

    /// Target frames for every tiled window; floating windows are left alone.
    public func frames(in bounds: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
        switch mode {
        case .float:
            return [:]
        case .stack where stacking == .accordion:
            return accordionFrames(in: bounds)
        case .stack:
            return Dictionary(uniqueKeysWithValues: tree.windows.map { ($0, bounds) })
        case .bsp:
            var frames = tree.frames(in: bounds, gap: gap)
            if let zoomed { frames[zoomed] = bounds }
            return frames
        }
    }

    /// The front window is inset by the accordion padding at each side that has windows beyond it.
    /// The windows before it sit to the left, showing in the strip at its left; those after it to the
    /// right. Every window keeps its stack position, so the strips don't jump as focus moves.
    func accordionFrames(in bounds: CGRect) -> [WindowID: CGRect] {
        let windows = tree.windows
        guard windows.count > 1 else { return Dictionary(uniqueKeysWithValues: windows.map { ($0, bounds) }) }
        let padding = min(Self.accordionPadding, bounds.width / 8)
        let frontIndex = front.flatMap(windows.firstIndex(of:)) ?? 0
        return Dictionary(uniqueKeysWithValues: windows.enumerated().map { index, window in
            let (leading, trailing): (CGFloat, CGFloat) = switch index {
            case ..<frontIndex: (0, 2 * padding)
            case frontIndex: (frontIndex > 0 ? padding : 0, frontIndex < windows.count - 1 ? padding : 0)
            default: (2 * padding, 0)
            }
            return (window, CGRect(x: bounds.minX + leading, y: bounds.minY, width: bounds.width - leading - trailing, height: bounds.height))
        })
    }

    /// The tiled window to focus when moving `direction` from `window`: the front window of the nearest tile.
    /// In stack mode east/south step forward through the stack and west/north step back, wrapping.
    public func neighbor(of window: WindowID, toward direction: Direction, in bounds: CGRect) -> WindowID? {
        switch mode {
        case .float:
            return nil
        case .stack:
            return cycle(from: window, forward: !direction.isLeading)
        case .bsp:
            // Zoom is ignored so neighbors follow the underlying tiles. Each tile is keyed by its
            // front window, and the origin tile by the front of `window`'s stack.
            let tiles = tree.tiles(in: bounds, gap: 0)
            guard let origin = tiles.first(where: { $0.windows.contains(window) })?.windows.first else { return nil }
            let fronts = Dictionary(uniqueKeysWithValues: tiles.filter { !BSPTree.isHole($0.windows[0]) }.map { ($0.windows[0], $0.rect) })
            return Self.nearest(to: origin, toward: direction, in: fronts)
        }
    }

    public mutating func swap(_ window: WindowID, toward direction: Direction, in bounds: CGRect) {
        guard let other = neighbor(of: window, toward: direction, in: bounds) else { return }
        tree.swap(window, other)
    }

    /// Exchanges tiled `window` with the front window of the pop target, on a Tile Space. On the
    /// window popped last it pops in instead.
    public mutating func popOut(_ window: WindowID, in bounds: CGRect) {
        if popped?.window == window { return popIn() }
        guard mode == .bsp, tree.contains(window), let target = popTarget(in: bounds), !target.contains(window) else { return }
        zoomed = nil
        tree.swap(window, target[0])
        popped = Pop(window: window, displaced: target[0])
    }

    /// Exchanges the last popped pair back, wherever they now sit.
    public mutating func popIn() {
        guard mode == .bsp, let popped, tree.contains(popped.window), tree.contains(popped.displaced) else { return }
        zoomed = nil
        tree.swap(popped.window, popped.displaced)
        self.popped = nil
    }

    /// Pop in has nothing to exchange back once either window has left the tree.
    private mutating func forgetPop(of window: WindowID) {
        if let popped, popped.window == window || popped.displaced == window { self.popped = nil }
    }

    /// The windows of the tile pop out exchanges with: the main tile under master and stack, else
    /// the largest (holes don't count), ties going to the topmost then leftmost.
    private func popTarget(in bounds: CGRect) -> [WindowID]? {
        let tiles = tree.tiles(in: bounds, gap: 0)
        let target = if tiling == .masterStack {
            // Mirrored, the main tile comes last in tree order
            tree.mainShape(defaultShare: 0.5).mainFirst ? tiles.first : tiles.last
        } else {
            // Rounded so split arithmetic can't break a tie between tiles that look the same size
            tiles.filter { !BSPTree.isHole($0.windows[0]) }.min {
                func rank(_ rect: CGRect) -> (CGFloat, CGFloat, CGFloat) { (-(rect.width * rect.height).rounded(), rect.minY, rect.minX) }
                return rank($0.rect) < rank($1.rect)
            }
        }
        guard let windows = target?.windows, !BSPTree.isHole(windows[0]) else { return nil }
        return windows
    }

    public mutating func moveEdge(_ edge: Direction, of window: WindowID, by points: CGFloat, in bounds: CGRect) {
        tree.moveEdge(edge, of: window, by: points, in: bounds)
    }

    /// The tile under `point` and what dropping `window` there would do, with the rect to highlight.
    /// The middle half of a tile swaps; elsewhere the nearest edge picks the side to insert on.
    public func drop(_ window: WindowID, at point: CGPoint, in bounds: CGRect, gap: CGFloat) -> (action: DropAction, highlight: CGRect)? {
        guard mode == .bsp, tree.contains(window),
              let tile = tree.tiles(in: bounds, gap: gap).first(where: { $0.rect.contains(point) }),
              let target = tile.windows.first(where: { $0 != window }) else { return nil }
        let rect = tile.rect
        // Dropped on a hole: the window fills it
        if BSPTree.isHole(target) { return (.swap(with: target), rect) }
        let x = (point.x - rect.minX) / rect.width, y = (point.y - rect.minY) / rect.height
        if (0.25...0.75).contains(x), (0.25...0.75).contains(y) {
            // Swapping within one stack would change nothing
            return tile.windows.contains(window) ? nil : (.swap(with: target), rect)
        }
        let side = [(Direction.west, x), (.east, 1 - x), (.north, y), (.south, 1 - y)].min { $0.1 < $1.1 }!.0
        let half = rect.split(along: side.axis, ratio: 0.5, gap: gap)
        return (.insert(beside: target, side: side), side.isLeading ? half.0 : half.1)
    }

    public mutating func perform(_ action: DropAction, dragging window: WindowID, in bounds: CGRect, gap: CGFloat) {
        zoomed = nil
        switch action {
        case .swap(let other):
            tree.swap(window, other)
        case let .insert(target, side):
            removeTiled(window)
            tree.insert(window, beside: target, in: bounds, gap: gap, preselect: side)
        }
    }

    public mutating func moveBorder(of window: WindowID, along axis: Axis, by points: CGFloat, in bounds: CGRect) {
        tree.moveBorder(of: window, along: axis, by: points, in: bounds)
    }

    public mutating func balance() { tree.balance() }
    public mutating func mirror(_ axis: Axis) { tree.mirror(axis) }
    public mutating func rotate(_ rotation: Rotation) { tree.rotate(rotation) }

    /// The closest tile whose leading edge lies beyond `window`'s edge in `direction` and which
    /// overlaps it on the other axis. Ties break toward the tile whose centre is best aligned, then
    /// toward the top-left so the choice never depends on dictionary order.
    static func nearest(to window: WindowID, toward direction: Direction, in frames: [WindowID: CGRect]) -> WindowID? {
        guard let origin = frames[window] else { return nil }
        let tolerance: CGFloat = 1
        let candidates = frames.compactMap { id, frame -> (WindowID, CGFloat, CGFloat, CGRect)? in
            guard id != window else { return nil }
            let (distance, overlaps, misalignment): (CGFloat, Bool, CGFloat) = switch direction {
            case .east: (frame.minX - origin.maxX, frame.minY < origin.maxY && frame.maxY > origin.minY, abs(frame.midY - origin.midY))
            case .west: (origin.minX - frame.maxX, frame.minY < origin.maxY && frame.maxY > origin.minY, abs(frame.midY - origin.midY))
            case .south: (frame.minY - origin.maxY, frame.minX < origin.maxX && frame.maxX > origin.minX, abs(frame.midX - origin.midX))
            case .north: (origin.minY - frame.maxY, frame.minX < origin.maxX && frame.maxX > origin.minX, abs(frame.midX - origin.midX))
            }
            return distance >= -tolerance && overlaps ? (id, distance, misalignment, frame) : nil
        }
        return candidates.min { ($0.1, $0.2, $0.3.minY, $0.3.minX) < ($1.1, $1.2, $1.3.minY, $1.3.minX) }?.0
    }
}
