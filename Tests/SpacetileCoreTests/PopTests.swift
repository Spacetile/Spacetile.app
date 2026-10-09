import CoreGraphics
import Testing
@testable import SpacetileCore

private func layout(root: Node, tiling: TileAlgorithm = .bsp) -> SpaceLayout {
    var layout = SpaceLayout(tiling: tiling)
    layout.tree = BSPTree(root: root)
    return layout
}

@Suite struct PopOut {
    // Layout of 1, 2, 3: 1 on the left half, 2 top right, 3 bottom right
    @Test func exchangesWithTheLargestTile() {
        var l = layout(1, 2, 3)
        l.popOut(3, in: screen)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[3] == rect(0, 0, 400, 500))
        #expect(frames[1] == rect(400, 250, 400, 250))
    }

    @Test func equalTilesGoToTheTopmostThenLeftmost() {
        var sideBySide = layout(1, 2)
        sideBySide.popOut(2, in: screen)
        #expect(sideBySide.tree.windows == [2, 1])

        // 2 (bottom left) comes first in the tree, but 3 (top right) is higher
        var staggered = layout(root: .split(axis: .horizontal, ratio: 0.5,
                                     first: .split(axis: .vertical, ratio: 0.3, first: .leaf(1), second: .leaf(2)),
                                     second: .split(axis: .vertical, ratio: 0.7, first: .leaf(3), second: .leaf(4))))
        staggered.popOut(1, in: screen)
        #expect(staggered.tree.windows == [3, 2, 1, 4])
    }

    @Test func skipsHoles() {
        var l = layout(root: .split(axis: .horizontal, ratio: 0.6, first: .leaf(BSPTree.firstHole),
                             second: .split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2))))
        l.popOut(2, in: screen)
        #expect(l.tree.leaves == [BSPTree.firstHole, 2, 1])
    }

    @Test func takesTheFrontOfAStackedTile() {
        var l = layout(root: .split(axis: .horizontal, ratio: 0.6, first: .tile([1, 2]), second: .leaf(3)))
        l.popOut(3, in: screen)
        #expect(l.tree.root == .split(axis: .horizontal, ratio: 0.6, first: .tile([3, 2]), second: .leaf(1)))
    }

    @Test func doesNothingFromInsideTheLargestTile() {
        let start = layout(root: .split(axis: .horizontal, ratio: 0.6, first: .tile([1, 2]), second: .leaf(3)))
        var l = start
        l.popOut(2, in: screen)
        #expect(l == start)
    }

    @Test func masterAndStackTakesTheMainTileWhateverItsSize() {
        var l = tiled(.masterStack, 1, 2, ratio: 0.4)
        l.popOut(2, in: screen)
        #expect(l.frames(in: screen, gap: 0)[2] == rect(0, 0, 320, 500))
    }

    @Test func onlyMovesTiledWindowsOnATileSpace() {
        let stacked = layout(1, 2, mode: .stack)
        var l = stacked
        l.popOut(2, in: screen)
        #expect(l == stacked)

        var withFloat = layout(1, 2)
        withFloat.add(3, beside: nil, in: screen, floating: true)
        let start = withFloat
        withFloat.popOut(3, in: screen)
        #expect(withFloat == start)
    }

    @Test func endsZoom() {
        var l = layout(1, 2, 3)
        l.toggleZoom(3)
        l.popOut(3, in: screen)
        #expect(l.zoomed == nil)
    }
}

@Suite struct PopIn {
    @Test func undoesPopOut() {
        let start = layout(1, 2, 3)
        var l = start
        l.popOut(3, in: screen)
        l.popIn()
        #expect(l == start)
    }

    @Test func popOutOnThePoppedWindowPopsIn() {
        let start = layout(1, 2, 3)
        var l = start
        l.popOut(3, in: screen)
        l.popOut(3, in: screen)
        #expect(l == start)
    }

    @Test func onlyOnATileSpace() {
        var l = layout(1, 2, 3)
        l.popOut(3, in: screen)
        l.mode = .stack
        let popped = l
        l.popIn()
        #expect(l == popped)
    }

    @Test(arguments: [WindowID(1), 3])
    func closingEitherWindowForgetsThePop(closed: WindowID) {
        var l = layout(1, 2, 3)
        l.popOut(3, in: screen)
        l.remove(closed)
        let after = l.tree
        l.popIn()
        #expect(l.tree == after)
    }

    @Test func aTabTakingOverKeepsThePop() {
        var l = layout(1, 2, 3)
        l.popOut(3, in: screen)
        l.replace(1, with: 4)
        l.popIn()
        #expect(l.tree.windows == [4, 2, 3])
    }

    @Test(arguments: [WindowID(1), 3])
    func floatingEitherWindowForgetsThePop(floated: WindowID) {
        var l = layout(1, 2, 3)
        l.popOut(3, in: screen)
        l.toggleFloat(floated, beside: nil, in: screen)
        #expect(l.popped == nil)
    }
}
