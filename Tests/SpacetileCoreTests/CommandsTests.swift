import CoreGraphics
import Testing
@testable import SpacetileCore

/// 1 | (2 / 3) on the 800×500 test screen.
@Suite struct Preselecting {
    @Test func nextWindowGoesBesidePreselectedWindowOnThatSide() {
        var l = layout(1, 2, 3)
        l.preselect(.north, beside: 1)
        l.add(4, beside: 3, in: screen)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[4] == CGRect(x: 0, y: 0, width: 400, height: 250))
        #expect(frames[1] == CGRect(x: 0, y: 250, width: 400, height: 250))
        #expect(l.preselection == nil)
    }

    @Test func sameDirectionAgainCancels() {
        var l = layout(1, 2)
        l.preselect(.west, beside: 2)
        l.preselect(.west, beside: 2)
        #expect(l.preselection == nil)
    }

    @Test func overlayShowsTheHalfTheWindowWillTake() {
        var l = layout(1, 2, 3)
        l.preselect(.east, beside: 1)
        #expect(l.preselectionRect(in: screen, gap: 0) == CGRect(x: 200, y: 0, width: 200, height: 500))
    }

    @Test func closingThePreselectedWindowClearsIt() {
        var l = layout(1, 2)
        l.preselect(.south, beside: 2)
        l.remove(2)
        #expect(l.preselection == nil)
    }
}

@Suite struct JoinAndSplit {
    @Test func joinStacksSideBySideWindows() {
        var l = layout(1, 2)
        l.join(1, toward: .east, in: screen, gap: 0)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 800, height: 250))
        #expect(frames[2] == CGRect(x: 0, y: 250, width: 800, height: 250))
    }

    @Test func joinKeepsOrderFromEitherSide() {
        var l = layout(1, 2)
        l.join(2, toward: .west, in: screen, gap: 0)
        #expect(l.frames(in: screen, gap: 0)[1]?.minY == 0)
    }

    @Test func joinPutsStackedWindowsSideBySide() {
        // 1 on the left, 2 above 3 on the right
        var l = layout(1, 2, 3)
        l.join(3, toward: .north, in: screen, gap: 0)
        let frames = l.frames(in: screen, gap: 0)
        #expect(frames[2] == CGRect(x: 400, y: 0, width: 200, height: 500))
        #expect(frames[3] == CGRect(x: 600, y: 0, width: 200, height: 500))
    }

    @Test func toggleSplitFlipsOnlyTheParentSplit() {
        var t = tree(1, 2, 3)
        t.toggleSplit(ofParentOf: 3)
        let frames = t.frames(in: screen, gap: 0)
        #expect(frames[2] == CGRect(x: 400, y: 0, width: 200, height: 500))
        #expect(frames[1]?.width == 400)
    }
}
