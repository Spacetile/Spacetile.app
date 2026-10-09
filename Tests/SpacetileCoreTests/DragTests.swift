import CoreGraphics
import Testing
@testable import SpacetileCore

/// 1 | (2 / 3) on the 800×500 test screen: 1 is x 0–400, 2 is top right, 3 bottom right.
@Suite struct Dropping {
    let l = layout(1, 2, 3)

    @Test func middleOfAnotherTileSwaps() {
        let drop = l.drop(1, at: CGPoint(x: 600, y: 125), in: screen, gap: 0)
        #expect(drop?.action == .swap(with: 2))
        #expect(drop?.highlight == CGRect(x: 400, y: 0, width: 400, height: 250))
    }

    @Test(arguments: [
        (CGPoint(x: 410, y: 125), Direction.west, CGRect(x: 400, y: 0, width: 200, height: 250)),
        (CGPoint(x: 790, y: 125), .east, CGRect(x: 600, y: 0, width: 200, height: 250)),
        (CGPoint(x: 600, y: 5), .north, CGRect(x: 400, y: 0, width: 400, height: 125)),
        (CGPoint(x: 600, y: 245), .south, CGRect(x: 400, y: 125, width: 400, height: 125)),
    ])
    func nearEdgeInsertsOnThatSide(point: CGPoint, side: Direction, highlight: CGRect) {
        let drop = l.drop(1, at: point, in: screen, gap: 0)
        #expect(drop?.action == .insert(beside: 2, side: side))
        #expect(drop?.highlight == highlight)
    }

    @Test func ownTileOrEmptySpaceDoesNothing() {
        #expect(l.drop(1, at: CGPoint(x: 200, y: 250), in: screen, gap: 0) == nil)
        #expect(l.drop(1, at: CGPoint(x: 900, y: 250), in: screen, gap: 0) == nil)
    }

    @Test func insertMovesWindowBesideTarget() {
        var moved = l
        moved.perform(.insert(beside: 3, side: .east), dragging: 1, in: screen, gap: 0)
        let frames = moved.frames(in: screen, gap: 0)
        #expect(frames[2] == CGRect(x: 0, y: 0, width: 800, height: 250))
        #expect(frames[1] == CGRect(x: 400, y: 250, width: 400, height: 250))
    }
}

@Suite struct EdgeResize {
    @Test func eastEdgeOfLeftWindowMovesMainSplit() {
        var t = tree(1, 2, 3)
        t.moveEdge(.east, of: 1, by: 80, in: screen)
        #expect(t.frames(in: screen, gap: 0)[1]?.width == 480)
    }

    @Test func westEdgeOfRightWindowMovesSameSplit() {
        var t = tree(1, 2, 3)
        t.moveEdge(.west, of: 3, by: -80, in: screen)
        #expect(t.frames(in: screen, gap: 0)[1]?.width == 320)
    }

    @Test func southEdgeOfTopRightOnlyMovesInnerSplit() {
        var t = tree(1, 2, 3)
        t.moveEdge(.south, of: 2, by: 50, in: screen)
        let frames = t.frames(in: screen, gap: 0)
        #expect(frames[2]?.height == 300)
        #expect(frames[1]?.width == 400)
    }

    @Test func screenBorderEdgeDoesNothing() {
        var t = tree(1, 2, 3)
        let before = t
        t.moveEdge(.west, of: 1, by: 50, in: screen)
        #expect(t == before)
    }
}
