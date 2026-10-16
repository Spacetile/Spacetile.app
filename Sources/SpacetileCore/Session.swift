/// The layouts Spacetile last left, saved as they change so a relaunch puts every window back in
/// its tile. A window keeps its number while its app runs, so the windows still open on the same
/// Space are matched exactly.
public struct Session: Codable, Equatable, Sendable {
    /// When the Mac last started, in seconds since 1970, and the window server's process ID, which
    /// changes when the user logs out. Window and Space numbers from another boot or login stand
    /// for other windows.
    public var boot: Int
    public var windowServer: Int32
    public var spaces: [Space]

    public struct Space: Codable, Equatable, Sendable {
        /// The window server's number for the Space.
        public var id: Int
        public var layout: SpaceSnapshot
        /// The window each of `layout`'s refs stood for.
        public var windows: [WindowRef: WindowID]
        /// The mode config.json gave the Space when saved, to tell a mode chosen while running from
        /// one config.json changed since.
        public var configuredMode: LayoutMode?

        public init(id: Int, layout: SpaceSnapshot, windows: [WindowRef: WindowID], configuredMode: LayoutMode?) {
            self.id = id
            self.layout = layout
            self.windows = windows
            self.configuredMode = configuredMode
        }

        /// The layout with only the windows `isHere` still finds, by window number and bundle ID,
        /// and those windows; nil when none are left. Settings changed while Spacetile wasn't running
        /// win, as they would for windows tracked afresh: a Space whose mode config.json now sets
        /// differently takes that mode, and windows a float rule now `floats` float.
        public func restorable(mode configured: LayoutMode, isHere: (WindowID, String) -> Bool,
                               floats: (WindowID) -> Bool) -> (layout: SpaceSnapshot, windows: [WindowRef: WindowID])? {
            let kept = windows.filter { isHere($0.value, $0.key.app) }
            guard !kept.isEmpty else { return nil }
            let ruled = Set(kept.filter { floats($0.value) }.keys)
            var restored = layout.keeping { kept[$0] != nil && !ruled.contains($0) }
            restored.floating = (restored.floating + ruled).sorted { ($0.app, $0.index) < ($1.app, $1.index) }
            if configuredMode != configured { restored.mode = configured }
            return (restored, kept)
        }
    }

    public init(boot: Int, windowServer: Int32, spaces: [Space]) {
        self.boot = boot
        self.windowServer = windowServer
        self.spaces = spaces
    }
}

extension SpaceSnapshot {
    /// This snapshot without the windows `keep` turns down. A split left with one side closes up, so
    /// no empty tile waits for a window that's gone.
    public func keeping(_ keep: (WindowRef) -> Bool) -> SpaceSnapshot {
        func walk(_ node: LayoutSnapshot) -> LayoutSnapshot? {
            switch node {
            case .tile(let refs):
                let kept = refs.filter(keep)
                return kept.isEmpty ? nil : .tile(kept)
            case let .split(axis, ratio, first, second):
                switch (walk(first), walk(second)) {
                case let (a?, b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil): return nil
                }
            }
        }
        return SpaceSnapshot(space: space, mode: mode, tree: tree.flatMap(walk), floating: floating.filter(keep),
                             others: others.filter(keep), display: display)
    }
}
