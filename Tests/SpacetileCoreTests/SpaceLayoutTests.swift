import CoreGraphics
import Testing
@testable import SpacetileCore

func layout(_ windows: WindowID..., mode: LayoutMode = .bsp) -> SpaceLayout {
    var layout = SpaceLayout(mode: mode)
    for window in windows { layout.add(window, beside: layout.tree.windows.last, in: screen) }
    return layout
}

@Suite struct Neighbors {
    // Layout of 1, 2, 3: 1 on the left, 2 top right, 3 bottom right
    @Test(arguments: [
        (WindowID(2), Direction.south, WindowID?.some(3)),
        (3, .north, 2),
        (3, .west, 1),
        (2, .west, 1),
        (1, .west, nil),
        (2, .east, nil),
    ])
    func bspFindsGeometricNeighbor(from: WindowID, direction: Direction, expected: WindowID?) {
        #expect(layout(1, 2, 3).neighbor(of: from, toward: direction, in: screen) == expected)
    }

    @Test func stackCyclesAndWraps() {
        let stack = layout(1, 2, 3, mode: .stack)
        #expect(stack.neighbor(of: 3, toward: .south, in: screen) == 1)
        #expect(stack.neighbor(of: 1, toward: .west, in: screen) == 3)
    }

    @Test func zoomDoesNotChangeNeighbors() {
        var l = layout(1, 2)
        l.toggleZoom(1)
        #expect(l.neighbor(of: 1, toward: .east, in: screen) == 2)
    }
}

@Suite struct Modes {
    @Test func stackGivesEveryWindowTheWholeArea() {
        #expect(layout(1, 2, mode: .stack).frames(in: screen, gap: 10) == [1: screen, 2: screen])
    }

    @Test func floatModePositionsNothing() {
        #expect(layout(1, 2, mode: .float).frames(in: screen, gap: 10).isEmpty)
    }

    @Test func zoomFillsAreaUntilToggledOrNewWindow() {
        var l = layout(1, 2)
        l.toggleZoom(1)
        #expect(l.frames(in: screen, gap: 0)[1] == screen)
        l.add(3, beside: 2, in: screen)
        #expect(l.zoomed == nil)
    }

    @Test func toggleFloatRoundTrips() {
        var l = layout(1, 2)
        l.toggleFloat(2, beside: 1, in: screen)
        #expect(l.frames(in: screen, gap: 0) == [1: screen])
        #expect(l.floating == [2])
        l.toggleFloat(2, beside: 1, in: screen)
        #expect(l.tree.windows == [1, 2])
    }
}

@Suite struct Rules {
    @Test(arguments: [
        ("Calculator", "Calculator", true),
        ("Finder", "Copy", true),
        ("Finder", "Documents", false),
        ("Zed", "Copy", false),
    ])
    func floatRules(app: String, title: String, floats: Bool) {
        #expect(FloatRules.default.floats(app: app, title: title) == floats)
    }

    @Test func spacingFollowsDisplayWidth() {
        #expect(Spacing.forDisplay(width: 2560).gap == 10)
        #expect(Spacing.forDisplay(width: 1512).gap == 5)
    }
}

@Suite struct WindowTabs {
    @Test func selectedTabTakesTheOldTabsTile() {
        var l = layout(1, 2)
        let before = l.frames(in: screen, gap: 0)[1]
        l.replace(1, with: 9)
        #expect(l.frames(in: screen, gap: 0)[9] == before)
        #expect(l.tree.windows.sorted() == [2, 9])
    }

    @Test func newTabsOwnTileClosesUp() {
        // ⌘T: the new tab got a tile of its own before the old one left the Space
        var l = layout(1, 2, 3)
        l.replace(1, with: 3)
        #expect(l.tree.windows.sorted() == [2, 3])
        #expect(l == { var r = layout(1, 2); r.replace(1, with: 3); return r }())
    }
}

@Suite struct MaximizeHeight {
    @Test func aWindowAtAnEdgeTakesThatEdgesFullHeight() {
        // 1 on the left, 2 above 3 on the right; 2 maximizes its height where it is
        var l = layout(1, 2, 3)
        l.place(2, in: .column(span: 0.5...1), bounds: screen)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[2] == CGRect(x: 400, y: 0, width: 400, height: 500))
        // The others keep their own arrangement in the left half
        #expect(frames.filter { $0.key != 2 }.values.allSatisfy { $0.maxX <= 400 })
    }

    @Test func aWindowInTheMiddleKeepsItsPlaceWithTheOthersEitherSide() {
        var l = layout(1, 2, 3)
        l.place(2, in: .column(span: 0.25...0.75), bounds: screen)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[2] == CGRect(x: 200, y: 0, width: 400, height: 500))
        // 1 was on the left; 3 was on the right
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 200, height: 500))
        #expect(frames[3] == CGRect(x: 600, y: 0, width: 200, height: 500))
    }

    @Test func restoreUndoesIt() {
        var l = layout(1, 2, 3)
        let before = l.tree
        l.place(2, in: .column(span: 0.5...1), bounds: screen)
        l.restore(in: screen)
        #expect(l.tree == before)
    }

    @Test func spanComesFromTheFrame() {
        #expect(Region.span(of: CGRect(x: 200, y: 100, width: 400, height: 100), in: screen) == 0.25...0.75)
        #expect(Command("place column") == .place(.column(span: nil)))
    }
}
