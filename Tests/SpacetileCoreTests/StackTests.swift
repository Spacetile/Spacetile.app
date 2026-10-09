import CoreGraphics
import Testing
@testable import SpacetileCore

@Suite struct StackOnOverflow {
    @Test func insertStacksWhenSplitWouldBeTooSmall() {
        var t = tree(1)
        // 1 needs more than half either way, so there's no split that leaves it room
        t.insert(2, beside: 1, in: screen, minimumSizes: [1: CGSize(width: 500, height: 300)])
        #expect(t.root == .tile([2, 1]))
    }

    @Test func insertSplitsAnotherTileWhenTheTargetHasNoRoom() {
        // 1 | 2: 1 can't share its half, but 2 can, so 3 goes below 2 rather than stacking with 1
        var t = tree(1, 2)
        t.insert(3, beside: 1, in: screen, minimumSizes: [1: CGSize(width: 400, height: 500)])
        #expect(t.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1),
                                 second: .split(axis: .vertical, ratio: 0.5, first: .leaf(2), second: .leaf(3))))
    }

    @Test func aWindowMayTakeUpToTheGapBeyondItsTile() {
        // Halves of 500pt with a 6pt gap are 247pt tall; 2 needs 250, 3pt short, within the gap
        var t = tree(1)
        t.insert(2, beside: 1, in: CGRect(x: 0, y: 0, width: 400, height: 500), gap: 6, minimumSizes: [2: CGSize(width: 0, height: 250)])
        #expect(t.root == .split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2)))
        // 10pt short is beyond the gap, and it's too wide to go beside 1: it stacks
        var u = tree(1)
        u.insert(2, beside: 1, in: CGRect(x: 0, y: 0, width: 400, height: 500), gap: 6, minimumSizes: [2: CGSize(width: 300, height: 257)])
        #expect(u.root == .tile([2, 1]))
    }

    @Test func insertSplitsWhenEveryoneFits() {
        var t = tree(1)
        t.insert(2, beside: 1, in: screen, minimumSizes: [1: CGSize(width: 400, height: 500)])
        #expect(t.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)))
    }

    @Test func normalizeMovesABorderToMakeRoom() {
        // 2 and 3 share the right half as 400×250 tiles; 3 needs 300pt of height, which 2 can give
        var t = tree(1, 2, 3)
        t.normalize(in: screen, gap: 0, minimumSizes: [3: CGSize(width: 0, height: 300)])
        #expect(t.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1),
                                 second: .split(axis: .vertical, ratio: 0.4, first: .leaf(2), second: .leaf(3))))
        // 1 needs 500pt of width: the right-hand column gives it up
        var u = tree(1, 2, 3)
        u.normalize(in: screen, gap: 0, minimumSizes: [1: CGSize(width: 500, height: 0)])
        #expect(u.root == .split(axis: .horizontal, ratio: 0.625, first: .leaf(1),
                                 second: .split(axis: .vertical, ratio: 0.5, first: .leaf(2), second: .leaf(3))))
    }

    @Test func normalizeMergesOverflowingTileIntoNeighbour() {
        // 2 and 3 both need 300pt of the right half's 500: no border gives both room
        var t = tree(1, 2, 3)
        t.normalize(in: screen, gap: 0, minimumSizes: [2: CGSize(width: 0, height: 300), 3: CGSize(width: 0, height: 300)])
        #expect(t.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .tile([3, 2])))
    }

    @Test func normalizeMergesAcrossSplitIntoAdjacentTile() {
        // 1 | (2 / 3): 1 needs 500pt of width and 2 needs 400, more than 800 between them, so 1
        // joins the right-hand tile that borders it
        var t = tree(1, 2, 3)
        t.normalize(in: screen, gap: 0, minimumSizes: [1: CGSize(width: 500, height: 0), 2: CGSize(width: 400, height: 0)])
        #expect(t.root == .split(axis: .vertical, ratio: 0.5, first: .tile([2, 1]), second: .leaf(3)))
    }

    @Test func normalizeUnstacksWhenThereIsRoom() {
        var t = BSPTree(root: .tile([1, 2]))
        t.normalize(in: screen, gap: 0, minimumSizes: [:])
        #expect(t.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)))
    }

    @Test func normalizeLeavesStackThatStillCannotSplit() {
        var t = BSPTree(root: .tile([1, 2]))
        t.normalize(in: screen, gap: 0, minimumSizes: [1: CGSize(width: 500, height: 0)])
        #expect(t.root == .tile([1, 2]))
    }

    @Test func removingFromStackKeepsTile() {
        var t = BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .tile([1, 2]), second: .leaf(3)))
        t.remove(1)
        #expect(t.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(2), second: .leaf(3)))
    }
}

@Suite struct StackNavigation {
    let stacked = BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .tile([1, 2, 3]), second: .leaf(4)))

    func layout(_ tree: BSPTree) -> SpaceLayout {
        var layout = SpaceLayout()
        for window in tree.windows { layout.add(window, beside: nil, in: screen) }
        return layout
    }

    @Test func focusRotatesStackSoCyclingKeepsDirection() {
        var t = stacked
        t.bringToFront(2)
        #expect(t.stack(containing: 1) == [2, 3, 1])
    }

    @Test func cycleWrapsWithinStack() {
        var l = SpaceLayout()
        l.add(1, beside: nil, in: screen)
        // 1 needs the whole Space, so 2 can only stack with it
        l.add(2, beside: 1, in: screen, minimumSizes: [1: CGSize(width: 800, height: 500)])
        #expect(l.cycle(from: 2, forward: true) == 1)
        #expect(l.cycle(from: 2, forward: false) == 1)
        #expect(l.stackedOutOfSight == 1)
    }

    @Test func neighbourLeadsToFrontOfStack() {
        var l = SpaceLayout()
        l.add(1, beside: nil, in: screen)
        l.add(2, beside: 1, in: screen)
        // Neither half can split, so 3 stacks with 2
        l.add(3, beside: 2, in: screen, minimumSizes: [1: CGSize(width: 400, height: 500), 2: CGSize(width: 400, height: 500)])
        // Right-hand tile is now the stack [3, 2]
        #expect(l.neighbor(of: 1, toward: .east, in: screen) == 3)
        #expect(l.neighbor(of: 2, toward: .west, in: screen) == 1)
    }
}
