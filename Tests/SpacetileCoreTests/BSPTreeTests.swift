import CoreGraphics
import Testing
@testable import SpacetileCore

/// An 800×500 screen: the first split is side by side, and the resulting 400×500 tiles split top/bottom.
let screen = CGRect(x: 0, y: 0, width: 800, height: 500)

/// Builds a tree by inserting windows in order, each beside the previous one.
func tree(_ windows: WindowID...) -> BSPTree {
    var tree = BSPTree()
    for (index, window) in windows.enumerated() {
        tree.insert(window, beside: index == 0 ? nil : windows[index - 1], in: screen)
    }
    return tree
}

@Suite struct Insertion {
    @Test func firstWindowFillsScreen() {
        #expect(tree(1).frames(in: screen, gap: 0) == [1: screen])
    }

    @Test func splitsLongerSideWithNewWindowSecond() {
        let frames = tree(1, 2, 3).frames(in: screen, gap: 0)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 400, height: 500))
        #expect(frames[2] == CGRect(x: 400, y: 0, width: 400, height: 250))
        #expect(frames[3] == CGRect(x: 400, y: 250, width: 400, height: 250))
    }

    @Test(arguments: [
        (Direction.west, CGRect(x: 0, y: 0, width: 400, height: 500)),
        (.east, CGRect(x: 400, y: 0, width: 400, height: 500)),
        (.north, CGRect(x: 0, y: 0, width: 800, height: 250)),
        (.south, CGRect(x: 0, y: 250, width: 800, height: 250)),
    ])
    func preselectPlacesNewWindow(direction: Direction, expected: CGRect) {
        var t = tree(1)
        t.insert(2, beside: 1, in: screen, preselect: direction)
        #expect(t.frames(in: screen, gap: 0)[2] == expected)
    }

    @Test func missingTargetFallsBackToLastWindow() {
        var t = tree(1, 2)
        t.insert(3, beside: 99, in: screen)
        #expect(t.windows == [1, 2, 3])
        #expect(t.frames(in: screen, gap: 0)[3]?.minX == 400)
    }

    @Test func gapSeparatesTiles() {
        let frames = tree(1, 2).frames(in: screen, gap: 10)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 395, height: 500))
        #expect(frames[2] == CGRect(x: 405, y: 0, width: 395, height: 500))
    }
}

@Suite struct Removal {
    @Test func siblingTakesParentTile() {
        var t = tree(1, 2, 3)
        t.remove(2)
        #expect(t.frames(in: screen, gap: 0)[3] == CGRect(x: 400, y: 0, width: 400, height: 500))
    }

    @Test func removingLastWindowEmptiesTree() {
        var t = tree(1)
        t.remove(1)
        #expect(t.root == nil)
    }
}

@Suite struct Transforms {
    @Test func swapExchangesTiles() {
        var t = tree(1, 2)
        t.swap(1, 2)
        #expect(t.windows == [2, 1])
    }

    @Test(arguments: [(CGFloat(100), 0.625), (-100, 0.375), (10_000, 0.9)])
    func moveBorderShiftsSplitAndClamps(points: CGFloat, ratio: Double) {
        for window: WindowID in [1, 2] {
            var t = tree(1, 2)
            t.moveBorder(of: window, along: .horizontal, by: points, in: screen)
            #expect(t.root == .split(axis: .horizontal, ratio: ratio, first: .leaf(1), second: .leaf(2)))
        }
    }

    @Test func moveBorderUsesDeepestSplitOnAxis() {
        var t = tree(1, 2, 3)
        t.moveBorder(of: 3, along: .vertical, by: 50, in: screen)
        let frames = t.frames(in: screen, gap: 0)
        #expect(frames[2]?.height == 300)
        #expect(frames[1]?.width == 400)
    }

    @Test func balanceEqualisesSameAxisRuns() {
        // Three windows side by side: 1 | (2 | 3) should become thirds
        var t = BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1),
                                     second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(2), second: .leaf(3))))
        t.balance()
        let widths = t.frames(in: CGRect(x: 0, y: 0, width: 900, height: 500), gap: 0).mapValues(\.width)
        #expect(widths == [1: 300, 2: 300, 3: 300])
    }

    @Test func mirrorSwapsOnlyMatchingAxis() {
        var t = tree(1, 2, 3)
        t.mirror(.horizontal)
        #expect(t.windows == [2, 3, 1])
        t.mirror(.vertical)
        #expect(t.windows == [3, 2, 1])
    }

    @Test(arguments: [
        (Rotation.quarter, [WindowID(1), 2]),
        (.half, [2, 1]),
        (.threeQuarter, [2, 1]),
    ])
    func rotateTurnsClockwise(rotation: Rotation, order: [WindowID]) {
        var t = tree(1, 2)
        t.rotate(rotation)
        #expect(t.windows == order)
        // A quarter or three-quarter turn makes the side-by-side pair stacked
        let stacked = rotation != .half
        #expect(t.frames(in: screen, gap: 0)[1]?.width == (stacked ? 800 : 400))
    }

    @Test func fourQuarterTurnsRestoreTree() {
        var t = tree(1, 2, 3)
        let original = t
        for _ in 0..<4 { t.rotate(.quarter) }
        #expect(t == original)
    }
}

@Suite struct Reinsertion {
    /// Removes `window`, then puts it back from the slot it had.
    func roundTrip(_ start: BSPTree, _ window: WindowID, meanwhile change: (inout BSPTree) -> Void = { _ in }) -> (BSPTree, Bool) {
        var tree = start
        let slot = tree.slot(of: window)!
        tree.remove(window)
        change(&tree)
        let placed = tree.reinsert(window, at: slot)
        return (tree, placed)
    }

    @Test(arguments: [1, 2, 3] as [WindowID])
    func windowGoesBackWhereItWas(window: WindowID) {
        let start = tree(1, 2, 3)
        #expect(roundTrip(start, window).0 == start)
    }

    @Test func keepsItsSplitRatio() {
        var start = tree(1, 2)
        start.moveBorder(of: 1, along: .horizontal, by: 200, in: screen)
        #expect(roundTrip(start, 2).0 == start)
    }

    @Test func rejoinsItsStackInPlace() {
        let start = BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .tile([1, 2, 3]), second: .leaf(4)))
        #expect(roundTrip(start, 2).0 == start)
    }

    @Test func goesBesideWhatsLeftOfItsNeighbours() {
        // 1 | (2 / 3): 1 leaves, then 3 closes; 1 still goes back to the left of 2
        let (tree, placed) = roundTrip(tree(1, 2, 3), 1) { $0.remove(3) }
        #expect(placed)
        #expect(tree.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)))
    }

    @Test func givesUpWhenItsNeighboursHaveGone() {
        let (_, placed) = roundTrip(tree(1, 2, 3), 1) { $0.remove(2); $0.remove(3); $0.insert(4, beside: nil, in: screen) }
        #expect(!placed)
    }
}
