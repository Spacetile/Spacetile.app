import CoreGraphics
import Foundation
import Testing
@testable import SpacetileCore

/// Desktops 1, 2, 3 with Safari full screen after Desktop 1 and Music after Desktop 3, as Mission
/// Control orders them.
private let laptop = DisplaySpaces(id: "L", identity: DisplayIdentity(name: "Built-in Retina Display", builtIn: true),
                                   frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   spaces: [1, 2, 3], current: 1, order: [1, 50, 2, 3, 60])

private func showing(_ current: Int) -> DisplaySpaces {
    DisplaySpaces(id: laptop.id, identity: laptop.identity, frame: laptop.frame, spaces: laptop.spaces, current: current, order: laptop.order)
}

@Suite struct FullScreenSpaces {
    @Test func theyAreNotDesktops() {
        let desktops = Desktops(displays: [laptop], activeID: "L")
        #expect(laptop.fullScreenSpaces == [50, 60])
        #expect(desktops.isFullScreen(50))
        #expect(!desktops.isFullScreen(2))
        #expect(desktops.number(of: 50) == nil)
        #expect(desktops.number(of: 2) == 2)
        #expect(desktops.display(of: 60) == laptop)
    }

    /// ⌥N counts full-screen Spaces, as Mission Control shows them; Desktop numbers, which labels,
    /// rules and profiles use, don't.
    @Test func positionsCountEverySpace() {
        let desktops = Desktops(displays: [laptop], activeID: "L")
        #expect(desktops.position(of: 1) == 1)
        #expect(desktops.position(of: 50) == 2)
        #expect(desktops.position(of: 2) == 3)
        #expect(desktops.number(of: 2) == 2)
        #expect(desktops.space(position: 2, on: laptop) == 50)
        #expect(desktops.space(position: 5, on: laptop) == 60)
        #expect(desktops.space(position: 6, on: laptop) == nil)
    }

    @Test func positionsWhenSpanning() throws {
        let screens = [(id: "A", identity: DisplayIdentity(name: "A"), frame: CGRect(x: 0, y: 0, width: 100, height: 100), index: 0),
                       (id: "B", identity: DisplayIdentity(name: "B"), frame: CGRect(x: 100, y: 0, width: 100, height: 100), index: 1)]
        let desktops = Desktops.spanning(screens: screens, spaces: [1, 2], current: 50, order: [1, 50, 2])
        let b = try #require(desktops.displays.last)
        #expect(desktops.space(position: 2, on: b) == 50)
        #expect(desktops.position(of: SpanningSpace.id(space: 2, display: 1)) == 3)
    }

    @Test func orderDefaultsToTheDesktops() {
        let plain = DisplaySpaces(id: "P", identity: DisplayIdentity(name: "P"), frame: .zero, spaces: [1, 2], current: 1)
        #expect(plain.order == [1, 2])
        #expect(plain.fullScreenSpaces.isEmpty)
    }

    /// Swipes step through full-screen Spaces too: Desktop 1 to Desktop 2 is two steps past Safari.
    @Test func switchingCountsEverySpace() {
        #expect(laptop.steps(to: 2) == 2)
        #expect(laptop.steps(to: 3) == 3)
        #expect(laptop.steps(to: 50) == 1)
        #expect(showing(60).steps(to: 1) == -4)
        #expect(laptop.steps(to: 99) == nil)
    }

    /// On a full-screen Space ⌥N still knows where it's starting from.
    @Test func switchingFromAFullScreenSpace() {
        #expect(showing(50).steps(to: 1) == -1)
        #expect(showing(50).steps(to: 3) == 2)
    }

    @Test func nextAndPreviousDesktopSkipFullScreen() {
        #expect(laptop.desktop(after: 1, forward: true) == 2)
        #expect(laptop.desktop(after: 3, forward: true) == 1)
        #expect(laptop.desktop(after: 50, forward: true) == 2)
        #expect(laptop.desktop(after: 50, forward: false) == 1)
        #expect(laptop.desktop(after: 1, forward: false) == 3)
    }

    @Test func nextAndPreviousFullScreenSkipDesktops() {
        #expect(laptop.fullScreenSpace(after: 1, forward: true) == 50)
        #expect(laptop.fullScreenSpace(after: 50, forward: true) == 60)
        #expect(laptop.fullScreenSpace(after: 60, forward: true) == 50)
        #expect(laptop.fullScreenSpace(after: 1, forward: false) == 60)
        let none = DisplaySpaces(id: "P", identity: DisplayIdentity(name: "P"), frame: .zero, spaces: [1, 2], current: 1)
        #expect(none.fullScreenSpace(after: 1, forward: true) == nil)
    }

    /// Spanning displays, a full-screen Space keeps the window server's ID on every display, while
    /// Desktops get per-display IDs.
    @Test func spanningKeepsFullScreenIDs() {
        let screens: [(id: String, identity: DisplayIdentity, frame: CGRect, index: Int)] = [
            ("A", DisplayIdentity(name: "A"), CGRect(x: 0, y: 0, width: 100, height: 100), 0),
            ("B", DisplayIdentity(name: "B"), CGRect(x: 100, y: 0, width: 100, height: 100), 1),
        ]
        let desktops = Desktops.spanning(screens: screens, spaces: [5, 6], current: 50, order: [5, 50, 6])
        let a = desktops.displays[0], b = desktops.displays[1]
        #expect(a.order == [SpanningSpace.id(space: 5, display: 0), 50, SpanningSpace.id(space: 6, display: 0)])
        #expect(b.order[1] == 50)
        #expect(a.current == 50 && b.current == 50)
        #expect(a.steps(to: a.spaces[1]) == 1)
    }

}

@Suite struct FullScreenCommands {
    @Test(arguments: [
        ("fullscreen", Command?.some(.toggleFullScreen)),
        ("fullscreen pair", .fullScreenPair),
        ("space fullscreen next", .stepFullScreen(forward: true)),
        ("space fullscreen prev", .stepFullScreen(forward: false)),
        ("space fullscreen", nil),
        ("fullscreen left", nil),
    ])
    func parse(text: String, command: Command?) {
        #expect(Command(text) == command)
        if let command { #expect(command.text == text) }
    }

    @Test func listedInKeys() {
        for command in ["fullscreen", "fullscreen pair", "space fullscreen next", "space fullscreen prev"] {
            #expect(KeyAction.listedCommands.contains(command))
            #expect(Command(command) != nil)
        }
    }

    @Test func profilesRecordFullScreenApps() throws {
        let safari = WindowRef(app: "com.apple.Safari", index: 0), notes = WindowRef(app: "com.apple.Notes", index: 0)
        let profile = Profile(name: "p", display: nil, spaces: [],
                              fullScreen: [FullScreenSnapshot(windows: [safari, notes])])
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(profile.apps == ["com.apple.Safari", "com.apple.Notes"])
        // Older profiles have none
        let old = try JSONDecoder().decode(Profile.self, from: Data(#"{"name": "old", "spaces": []}"#.utf8))
        #expect(old.fullScreen == nil)
    }

    @Test func settingsDefaults() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(Settings.default))
        #expect(decoded.adoptsNativeTiling)
        #expect(decoded.fullScreenRules.isEmpty)
        #expect(Settings.default.keys["alt-shift-f"] == "fullscreen")
    }
}

/// The laptop's visible frame below the menu bar, in top-left coordinates.
private let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)

@Suite struct NativeTileReading {
    @Test func halvesAndQuarters() {
        let (left, right) = visible.split(along: .horizontal, ratio: 0.5, gap: 0)
        let (top, bottom) = visible.split(along: .vertical, ratio: 0.5, gap: 0)
        #expect(NativeTiling.classify(left, in: visible) == .region(.edge(.west, fraction: 0.5)))
        #expect(NativeTiling.classify(right, in: visible) == .region(.edge(.east, fraction: 0.5)))
        #expect(NativeTiling.classify(top, in: visible) == .region(.edge(.north, fraction: 0.5)))
        #expect(NativeTiling.classify(bottom, in: visible) == .region(.edge(.south, fraction: 0.5)))
        let (topRight, _) = right.split(along: .vertical, ratio: 0.5, gap: 0)
        #expect(NativeTiling.classify(topRight, in: visible) == .region(.corner(vertical: .north, horizontal: .east)))
        #expect(NativeTiling.classify(visible, in: visible) == .fill)
    }

    /// With "Tiled windows have margins" on, each tile sits a few points inside its share.
    @Test func marginsStillCount() {
        let (left, _) = visible.split(along: .horizontal, ratio: 0.5, gap: 8)
        #expect(NativeTiling.classify(left.insetBy(dx: 6, dy: 6), in: visible) == .region(.edge(.west, fraction: 0.5)))
        #expect(NativeTiling.classify(visible.insetBy(dx: 6, dy: 6), in: visible) == .fill)
    }

    @Test func otherFramesAreNotTiles() {
        #expect(NativeTiling.classify(CGRect(x: 100, y: 100, width: 800, height: 600), in: visible) == nil)
        // A third isn't a native tile
        let (third, _) = visible.split(along: .horizontal, ratio: 1.0 / 3, gap: 0)
        #expect(NativeTiling.classify(third, in: visible) == nil)
    }
}

@Suite struct FramesToTree {
    private func frames(of tree: BSPTree) -> [WindowID: CGRect] { tree.frames(in: visible, gap: 10) }

    @Test func fiftyFifty() {
        let (left, right) = visible.split(along: .horizontal, ratio: 0.5, gap: 8)
        let tree = NativeTiling.tree(from: [1: left, 2: right])
        #expect(tree == BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))))
    }

    @Test func oneAndTwo() {
        let source = BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1),
                                          second: .split(axis: .vertical, ratio: 0.5, first: .leaf(2), second: .leaf(3))))
        #expect(NativeTiling.tree(from: frames(of: source)) == source)
    }

    /// A 2 × 2 grid cuts into columns first, as side by side comes before stacked.
    @Test func grid() {
        let source = BSPTree(root: .split(axis: .horizontal, ratio: 0.5,
                                          first: .split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2)),
                                          second: .split(axis: .vertical, ratio: 0.5, first: .leaf(3), second: .leaf(4))))
        #expect(NativeTiling.tree(from: frames(of: source)) == source)
    }

    /// Any guillotine layout comes back as the tree that drew it, ratios within rounding.
    @Test func roundTrips() {
        let source = BSPTree(root: .split(axis: .vertical, ratio: 0.3,
                                          first: .split(axis: .horizontal, ratio: 0.7, first: .leaf(1), second: .leaf(2)),
                                          second: .split(axis: .horizontal, ratio: 0.25, first: .leaf(3),
                                                         second: .split(axis: .vertical, ratio: 0.5, first: .leaf(4), second: .leaf(5)))))
        let tree = NativeTiling.tree(from: frames(of: source))
        #expect(tree?.windows == source.windows)
        for (id, frame) in frames(of: source) {
            let back = tree?.frames(in: visible, gap: 10)[id]
            #expect(back.map { abs($0.minX - frame.minX) < 4 && abs($0.width - frame.width) < 4 && abs($0.height - frame.height) < 4 } == true)
        }
    }

    @Test func overlappingFramesStack() {
        let tree = NativeTiling.tree(from: [1: visible, 2: visible.insetBy(dx: 2, dy: 2)])
        #expect(tree?.root.map { if case .tile(let windows) = $0 { Set(windows) == [1, 2] } else { false } } == true)
    }

    /// A pinwheel of four windows has no straight cut.
    @Test func uncuttable() {
        let pinwheel: [WindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 200, height: 100), 2: CGRect(x: 200, y: 0, width: 100, height: 200),
            3: CGRect(x: 100, y: 200, width: 200, height: 100), 4: CGRect(x: 0, y: 100, width: 100, height: 200),
        ]
        #expect(NativeTiling.tree(from: pinwheel) == nil)
        #expect(NativeTiling.tree(from: [:]) == nil)
    }

    @Test func coverage() {
        let (left, right) = visible.split(along: .horizontal, ratio: 0.5, gap: 8)
        #expect(NativeTiling.covers([left, right], visible))
        #expect(!NativeTiling.covers([left], visible))
    }
}

@Suite struct AdoptingArrangements {
    @Test func othersStackBehindTheLastTile() {
        var layout = SpaceLayout()
        for id: WindowID in [1, 2, 3] { layout.add(id, beside: nil, in: visible) }
        let arranged = BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(3), second: .leaf(1)))
        layout.adopt(arranged)
        #expect(layout.tree.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(3), second: .tile([1, 2])))
        layout.restore(in: visible)
        #expect(Set(layout.tree.windows) == [1, 2, 3])
        #expect(layout.tree.root != .split(axis: .horizontal, ratio: 0.5, first: .leaf(3), second: .tile([1, 2])))
    }

    @Test func floatingWindowsJoin() {
        var layout = SpaceLayout()
        layout.add(1, beside: nil, in: visible)
        layout.add(2, beside: nil, in: visible, floating: true)
        layout.adopt(BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))))
        #expect(layout.floating.isEmpty)
        #expect(layout.tree.windows == [1, 2])
    }

    /// Two windows tiled into the bottom quarters: they keep the bottom half, the rest the top.
    @Test func inHalfTheOthersKeepTheOtherHalf() throws {
        var layout = SpaceLayout()
        for id: WindowID in [1, 2, 3, 4] { layout.add(id, beside: nil, in: visible) }
        let (_, bottom) = visible.split(along: .vertical, ratio: 0.5, gap: 0)
        let (bottomLeft, bottomRight) = bottom.split(along: .horizontal, ratio: 0.5, gap: 0)
        let frames: [WindowID: CGRect] = [3: bottomLeft, 4: bottomRight]
        let arranged = try #require(NativeTiling.tree(from: frames))
        let area = frames.values.reduce(CGRect.null) { $0.union($1) }
        #expect(NativeTiling.classify(area, in: visible) == .region(.edge(.south, fraction: 0.5)))
        #expect(!NativeTiling.covers(Array(frames.values), visible))

        layout.adopt(arranged, inHalf: .south)
        guard case let .split(axis, ratio, first, second)? = layout.tree.root else {
            Issue.record("no split")
            return
        }
        #expect(axis == Direction.south.axis && ratio == 0.5)
        #expect(Set(BSPTree(root: first).windows) == [1, 2])
        #expect(second == arranged.root)
        layout.restore(in: visible)
        #expect(Set(layout.tree.windows) == [1, 2, 3, 4])
    }

    /// With no other windows, a hole holds the other half, as `place` leaves one.
    @Test func inHalfAloneLeavesAHole() {
        var layout = SpaceLayout()
        for id: WindowID in [1, 2] { layout.add(id, beside: nil, in: visible) }
        let arranged = BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)))
        layout.adopt(arranged, inHalf: .west)
        guard case let .split(_, _, first, second)? = layout.tree.root, case let .tile(other) = second else {
            Issue.record("no split")
            return
        }
        #expect(first == arranged.root)
        #expect(other.count == 1 && BSPTree.isHole(other[0]))
    }

    @Test func zoomStaysOn() {
        var layout = SpaceLayout()
        for id: WindowID in [1, 2] { layout.add(id, beside: nil, in: visible) }
        layout.zoom(1)
        layout.zoom(1)
        #expect(layout.zoomed == 1)
    }
}

/// `TileLayoutManager` entries as macOS 27 reported them for ChatGPT full screen and a Safari |
/// Chrome Split View on a 1512 × 982 display (fullscreen-probe, 2026-10-03), trimmed to the keys read.
@Suite struct FullScreenTileReading {
    private func entry(_ tiles: [(window: Int, x: Int, width: Int)], pid: Any) -> [String: Any] {
        ["type": 4, "ManagedSpaceID": 314, "pid": pid, "fs_wid": tiles[0].window,
         "TileLayoutManager": [
            "Layout Rect": ["X": 0, "Y": 0, "Width": 1512, "Height": 982],
            "Inter-Tile Spacing": ["Width": 12, "Height": 12],
            "TileSpaces": tiles.map { tile -> [String: Any] in
                ["TileWindowID": tile.window, "TileType": "Primary", "type": 5,
                 "TileRect": ["X": tile.x, "Y": 0, "Width": tile.width, "Height": 982]]
            },
         ] as [String: Any]]
    }

    @Test func oneApp() {
        let tiles = FullScreenTiles(entry: entry([(1419, 0, 1512)], pid: 63724))
        #expect(tiles?.windows == [1419])
        #expect(tiles?.ratio == nil)
    }

    /// Split View lists both pids as an array; the tiles give the windows and the divider.
    @Test func splitView() {
        let tiles = FullScreenTiles(entry: entry([(1612, 711, 801), (3610, 0, 699)], pid: [68617, 63734]))
        #expect(tiles?.windows == [3610, 1612])
        #expect(tiles?.area == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(tiles.flatMap(\.ratio).map { abs($0 - 699.0 / 1512) < 0.0001 } == true)
    }

    /// Reads what CoreFoundation hands over (NSNumbers), not only Swift literals.
    @Test func bridgedNumbers() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entry([(1419, 0, 1512)], pid: 1), format: .binary, options: 0)
        let bridged = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(FullScreenTiles(entry: bridged)?.tiles == [.init(window: 1419, rect: CGRect(x: 0, y: 0, width: 1512, height: 982))])
    }

    @Test func otherShapesReadAsNothing() {
        #expect(FullScreenTiles(entry: ["type": 4, "ManagedSpaceID": 78]) == nil)
        #expect(FullScreenTiles(entry: ["TileLayoutManager": ["TileSpaces": [["TileWindowID": 1]]]]) == nil)
    }

    @Test func desktopsFindThem() {
        let tiles = FullScreenTiles(tiles: [.init(window: 7, rect: CGRect(x: 0, y: 0, width: 1512, height: 982))],
                                    area: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let display = DisplaySpaces(id: laptop.id, identity: laptop.identity, frame: laptop.frame, spaces: laptop.spaces,
                                    current: 1, order: laptop.order, fullScreen: [50: tiles])
        let desktops = Desktops(displays: [display], activeID: "L")
        #expect(desktops.tiles(of: 50) == tiles)
        #expect(desktops.tiles(of: 60) == nil)
        #expect(desktops.tiles(of: 2) == nil)
    }
}
