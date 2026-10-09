import CoreGraphics
import Testing
@testable import SpacetileCore

/// 1 | (2 / 3) on the 800×500 test screen unless stated.
@Suite struct Placing {
    @Test func edgeMakesAColumnAndOthersKeepTheirShape() {
        var l = layout(1, 2, 3)
        l.place(3, in: .edge(.west, fraction: nil), bounds: screen)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[3] == CGRect(x: 0, y: 0, width: 400, height: 500))
        #expect(frames[1] == CGRect(x: 400, y: 0, width: 200, height: 500))
        #expect(frames[2] == CGRect(x: 600, y: 0, width: 200, height: 500))
    }

    @Test func repeatingAnEdgeCyclesHalfTwoThirdsThird() {
        // 2 starts on the right, so its first press to the left gives a half
        var l = layout(1, 2)
        var widths: [CGFloat] = []
        for _ in 0..<4 {
            l.place(2, in: .edge(.west, fraction: nil), bounds: CGRect(x: 0, y: 0, width: 900, height: 500))
            widths.append(l.frames(in: CGRect(x: 0, y: 0, width: 900, height: 500), gap: 0)[2]!.width)
        }
        #expect(widths == [450, 600, 300, 450])
    }

    @Test func aWindowAlreadyOnThatEdgeAtAHalfStepsToTwoThirds() {
        var l = layout(1, 2)
        l.place(1, in: .edge(.west, fraction: nil), bounds: screen)
        #expect(l.frames(in: screen, gap: 0)[1]?.width == 533)
    }

    @Test func explicitFractionOnTheTrailingEdge() {
        var l = layout(1, 2)
        l.place(1, in: .edge(.east, fraction: 0.75), bounds: screen)
        #expect(l.frames(in: screen, gap: 0)[1] == CGRect(x: 200, y: 0, width: 600, height: 500))
    }

    @Test func aLoneWindowGetsAHoleForTheRest() {
        var l = layout(1)
        l.place(1, in: .edge(.north, fraction: nil), bounds: screen)
        #expect(l.frames(in: screen, gap: 0)[1] == CGRect(x: 0, y: 0, width: 800, height: 250))
        #expect(l.tree.holes.count == 1)
        // The next window fills the hole
        l.add(2, beside: 1, in: screen)
        #expect(l.tree.holes.isEmpty)
        #expect(l.frames(in: screen, gap: 0)[2] == CGRect(x: 0, y: 250, width: 800, height: 250))
    }

    @Test func cornerSharesItsColumnWithTheNeighbourBelow() {
        var l = layout(1, 2, 3)
        l.place(2, in: .corner(vertical: .north, horizontal: .west), bounds: screen)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[2] == CGRect(x: 0, y: 0, width: 400, height: 250))
        #expect(frames[3] == CGRect(x: 0, y: 250, width: 400, height: 250))
        #expect(frames[1] == CGRect(x: 400, y: 0, width: 400, height: 500))
    }

    @Test func cornerWithTwoWindowsUsesAHole() {
        var l = layout(1, 2)
        l.place(1, in: .corner(vertical: .south, horizontal: .east), bounds: screen)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[1] == CGRect(x: 400, y: 250, width: 400, height: 250))
        #expect(frames[2] == CGRect(x: 0, y: 0, width: 400, height: 500))
        #expect(l.tree.holes.count == 1)
    }

    @Test func centerSplitsTheOthersEitherSide() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 500)
        var l = layout(1, 2, 3)
        l.place(3, in: .center, bounds: bounds)
        let frames = l.frames(in: bounds, gap: 0)
        #expect(frames[3] == CGRect(x: 300, y: 0, width: 300, height: 500))
        #expect(frames[1]?.minX == 0)
        #expect(frames[2]?.minX == 600)
    }

    @Test func sixthPutsTheWindowInItsCellAndHolesInEmptyOnes() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 500)
        var l = layout(1, 2)
        l.place(1, in: .sixth(column: 1, row: 1), bounds: bounds)
        #expect(l.frames(in: bounds, gap: 0)[1] == CGRect(x: 300, y: 250, width: 300, height: 250))
        #expect(l.tree.holes.count == 4)
    }

    @Test func holesSkipFocusAndVanishWhenAWindowCloses() {
        var l = layout(1, 2)
        l.place(1, in: .corner(vertical: .north, horizontal: .west), bounds: screen)
        #expect(l.neighbor(of: 1, toward: .south, in: screen) == nil)
        l.remove(2)
        #expect(l.tree.holes.isEmpty)
    }

    @Test func droppingOnAHoleFillsIt() {
        var l = layout(1, 2)
        l.place(1, in: .corner(vertical: .north, horizontal: .west), bounds: screen)
        // The hole sits below 1, bottom left
        let drop = l.drop(2, at: CGPoint(x: 200, y: 400), in: screen, gap: 0)
        l.perform(drop!.action, dragging: 2, in: screen, gap: 0)
        #expect(l.tree.holes.isEmpty)
        #expect(l.frames(in: screen, gap: 0)[2] == CGRect(x: 0, y: 250, width: 800, height: 250))
    }
}

@Suite struct GrowShrinkRestore {
    @Test func growMovesEveryInnerBorderOutwards() {
        var l = layout(1, 2, 3)
        l.resize(2, grow: true, in: screen)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[2] == CGRect(x: 320, y: 0, width: 480, height: 300))
    }

    /// Window 3, under 2, can't be shorter than 230: the bottom border moves only as far as that
    /// allows, and 3 keeps a tile of its own rather than stacking.
    @Test func growStopsAtANeighboursMinimumSize() {
        var l = layout(1, 2, 3)
        let minimumSizes: MinimumSizes = [3: CGSize(width: 0, height: 230)]
        for _ in 0..<3 { l.resize(2, grow: true, in: screen, minimumSizes: minimumSizes) }
        let frames = l.frames(in: screen, gap: 0)
        #expect(!l.tree.overflows(in: screen, gap: 0, minimumSizes: minimumSizes))
        #expect(frames[3].map { $0.height >= 230 } == true)
        #expect(frames[2] != frames[3])
        #expect(frames[2].map { $0.minX < 320 } == true)
    }

    @Test func restoreUndoesThePlacement() {
        var l = layout(1, 2, 3)
        let before = l.tree
        l.place(3, in: .edge(.west, fraction: nil), bounds: screen)
        l.restore(in: screen)
        #expect(l.tree == before)
    }

    @Test func restoreUndoesAWholeRunOfSizing() {
        var l = layout(1, 2, 3)
        let before = l.tree
        for _ in 0..<3 { l.place(3, in: .edge(.west, fraction: nil), bounds: screen) }
        l.resize(3, grow: true, in: screen)
        l.restore(in: screen)
        #expect(l.tree == before)
    }

    @Test func restoreKeepsTheHolesItHad() {
        var l = layout(1, 2)
        l.place(2, in: .corner(vertical: .north, horizontal: .east), bounds: screen)
        l.endSizingRun()
        let corner = l.tree
        l.resize(2, grow: true, in: screen)
        l.restore(in: screen)
        #expect(l.tree == corner)
    }

    @Test func restoreKeepsWindowsOpenedSince() {
        var l = layout(1, 2)
        l.place(1, in: .edge(.west, fraction: nil), bounds: screen)
        l.add(3, beside: 2, in: screen)
        l.restore(in: screen)
        #expect(Set(l.tree.windows) == [1, 2, 3])
    }

    @Test func newWindowsKeepTheDefaultRatio() {
        var l = layout(1)
        l.add(2, beside: 1, in: screen, ratio: 0.6)
        #expect(l.frames(in: screen, gap: 0)[1]?.width == 480)
    }

    @Test(arguments: [
        (Region.edge(.west, fraction: nil), CGRect(x: 0, y: 0, width: 450, height: 500)),
        (.corner(vertical: .south, horizontal: .east), CGRect(x: 450, y: 250, width: 450, height: 250)),
        (.center, CGRect(x: 300, y: 0, width: 300, height: 500)),
        (.sixth(column: 2, row: 0), CGRect(x: 600, y: 0, width: 300, height: 250)),
    ])
    func floatingRects(region: Region, rect: CGRect) {
        #expect(region.rect(in: CGRect(x: 0, y: 0, width: 900, height: 500), gap: 0) == rect)
    }
}
