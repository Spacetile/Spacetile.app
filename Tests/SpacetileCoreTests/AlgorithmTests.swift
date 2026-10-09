import CoreGraphics
import Foundation
import Testing
@testable import SpacetileCore

/// Adds windows in order, each beside the one before, as focus following new windows would.
func tiled(_ algorithm: TileAlgorithm, _ windows: WindowID..., ratio: Double = 0.5) -> SpaceLayout {
    var layout = SpaceLayout(tiling: algorithm)
    for window in windows { layout.add(window, beside: layout.tree.windows.last, in: screen, ratio: ratio) }
    return layout
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

@Suite struct I3Tiling {
    @Test func newWindowsJoinTheRowEvenly() {
        let frames = tiled(.i3, 1, 2, 3, 4).frames(in: screen, gap: 0)
        #expect(frames == [1: rect(0, 0, 200, 500), 2: rect(200, 0, 200, 500), 3: rect(400, 0, 200, 500), 4: rect(600, 0, 200, 500)])
    }

    @Test func newWindowGoesJustAfterTheFocusedOne() {
        var layout = tiled(.i3, 1, 2, 3)
        layout.add(4, beside: 1, in: screen)
        #expect(layout.tree.windows == [1, 4, 2, 3])
    }

    @Test func newWindowTakesAnAverageShareTheOthersGiveUpInProportion() {
        var layout = tiled(.i3, 1, 2)
        layout.moveBorder(of: 1, along: .horizontal, by: 200, in: screen)
        // 1 has 600 of 800, 2 has 200; a third takes a third and the others keep their 3:1
        layout.add(3, beside: 2, in: screen)
        let frames = layout.frames(in: screen, gap: 0)
        #expect(frames[1]!.width == 400)
        #expect(frames[2]!.width.rounded() == 133)
        #expect(frames[3]!.width.rounded() == 267)
    }

    @Test func joiningInsideAColumnStaysInTheColumn() {
        var layout = tiled(.i3, 1, 2, 3)
        // 2 and 3 one above the other, beside 1, which gets back the row's other half
        layout.join(3, toward: .west, in: screen, gap: 0)
        #expect(layout.frames(in: screen, gap: 0) == [1: rect(0, 0, 400, 500), 2: rect(400, 0, 400, 250), 3: rect(400, 250, 400, 250)])
        layout.add(4, beside: 3, in: screen)
        let frames = layout.frames(in: screen, gap: 0)
        #expect(frames[1] == rect(0, 0, 400, 500))
        #expect(frames.filter { $0.key != 1 }.values.allSatisfy { $0.minX == 400 && $0.width == 400 })
        #expect(Set(frames.filter { $0.key != 1 }.values.map { $0.height.rounded() }) == [167, 166])
    }

    @Test func closingAWindowSharesItsSpaceWithTheWholeRow() {
        var layout = tiled(.i3, 1, 2, 3, 4)
        layout.remove(2)
        let widths = layout.frames(in: screen, gap: 0).mapValues { $0.width.rounded() }
        #expect(Set(widths.values).isSubset(of: [266, 267]))
        #expect(layout.tree.windows == [1, 3, 4])
    }

    @Test func closingTheLastOfAColumnLeavesTheRestAlone() {
        var layout = tiled(.i3, 1, 2, 3)
        layout.toggleSplit(of: 3)
        #expect(layout.frames(in: screen, gap: 0)[3] == rect(0, 334, 800, 166))
        layout.remove(3)
        #expect(layout.frames(in: screen, gap: 0) == [1: rect(0, 0, 800, 250), 2: rect(0, 250, 800, 250)])
    }

    @Test func splitTogglesTheWholeRow() {
        var layout = tiled(.i3, 1, 2, 3)
        layout.toggleSplit(of: 2)
        #expect(layout.frames(in: screen, gap: 0).values.allSatisfy { $0.minX == 0 && $0.width == 800 })
    }

    @Test func leavingAStackKeepsTheTile() {
        var tree = BSPTree(root: .split(axis: .horizontal, ratio: 0.5, first: .tile([1, 2]), second: .leaf(3)))
        tree.removeFromContainer(2)
        #expect(tree.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(3)))
    }

    @Test func preselectionStillSplitsTheTile() {
        var layout = tiled(.i3, 1, 2)
        layout.preselect(.south, beside: 2)
        layout.add(3, beside: 2, in: screen)
        #expect(layout.frames(in: screen, gap: 0)[3] == rect(400, 250, 400, 250))
    }
}

@Suite struct MasterStackTiling {
    @Test func mainWindowOnTheLeftOthersShareAColumn() {
        let frames = tiled(.masterStack, 1, 2, 3, 4).frames(in: screen, gap: 0)
        #expect(frames[1] == rect(0, 0, 400, 500))
        #expect(frames[2] == rect(400, 0, 400, 167))
        #expect(frames[3]!.minY == 167 && frames[4]!.maxY == 500)
    }

    @Test func mainWindowKeepsTheRatio() {
        #expect(tiled(.masterStack, 1, 2, 3, ratio: 0.6).frames(in: screen, gap: 0)[1] == rect(0, 0, 480, 500))
    }

    @Test func newWindowsGoToTheEndOfTheStack() {
        var layout = tiled(.masterStack, 1, 2, 3)
        layout.add(4, beside: 1, in: screen)
        #expect(layout.tree.windows == [1, 2, 3, 4])
    }

    @Test func resizedMainKeepsItsShareAsWindowsComeAndGo() {
        var layout = tiled(.masterStack, 1, 2, 3)
        layout.moveBorder(of: 1, along: .horizontal, by: 160, in: screen)
        layout.add(4, beside: 4, in: screen)
        layout.remove(2)
        #expect(layout.frames(in: screen, gap: 0)[1] == rect(0, 0, 560, 500))
    }

    @Test func closingTheMainWindowPromotesTheFirstOfTheStack() {
        var layout = tiled(.masterStack, 1, 2, 3)
        layout.remove(1)
        #expect(layout.frames(in: screen, gap: 0) == [2: rect(0, 0, 400, 500), 3: rect(400, 0, 400, 500)])
    }

    @Test func swappingIntoTheMainTilePromotes() {
        var layout = tiled(.masterStack, 1, 2, 3)
        layout.swap(3, toward: .west, in: screen)
        #expect(layout.frames(in: screen, gap: 0)[3] == rect(0, 0, 400, 500))
    }

    @Test func mirroredMainStaysOnTheRight() {
        var layout = tiled(.masterStack, 1, 2, 3)
        layout.mirror(.horizontal)
        layout.add(4, beside: 1, in: screen)
        let frames = layout.frames(in: screen, gap: 0)
        #expect(frames[1] == rect(400, 0, 400, 500))
        #expect(frames[4]!.minX == 0 && frames[4]!.maxY == 500)
    }

    @Test func rotatedPutsTheStackBelow() {
        var layout = tiled(.masterStack, 1, 2, 3)
        layout.rotate(.quarter)
        layout.add(4, beside: 1, in: screen)
        let frames = layout.frames(in: screen, gap: 0)
        #expect(frames[1]!.width == 800)
        #expect([2, 3, 4].allSatisfy { frames[$0]!.height == frames[2]!.height && frames[$0]!.minY == frames[2]!.minY })
    }

    @Test func switchingToMasterStackReshapesTheTree() {
        var layout = tiled(.bsp, 1, 2, 3, 4)
        layout.setTiling(.masterStack)
        let frames = layout.frames(in: screen, gap: 0)
        #expect(frames[1] == rect(0, 0, 400, 500))
        #expect([2, 3, 4].allSatisfy { frames[$0]!.minX == 400 && frames[$0]!.width == 400 })
    }

    @Test func floatingAndUnfloatingRejoinsTheStack() {
        var layout = tiled(.masterStack, 1, 2, 3)
        layout.toggleFloat(2, beside: 1, in: screen)
        #expect(layout.frames(in: screen, gap: 0) == [1: rect(0, 0, 400, 500), 3: rect(400, 0, 400, 500)])
        layout.toggleFloat(2, beside: 1, in: screen)
        #expect(layout.tree.windows == [1, 3, 2])
    }
}

@Suite struct AccordionStacking {
    func accordion(_ windows: WindowID...) -> SpaceLayout {
        var layout = SpaceLayout(mode: .stack, stacking: .accordion)
        for window in windows { layout.add(window, beside: layout.tree.windows.last, in: screen) }
        return layout
    }

    @Test func aloneFillsTheSpace() {
        #expect(accordion(1).frames(in: screen, gap: 10) == [1: screen])
    }

    @Test func frontWindowLeavesStripsForTheWindowsEitherSide() {
        var layout = accordion(1, 2, 3, 4)
        layout.focus(3)
        let p = SpaceLayout.accordionPadding
        #expect(layout.frames(in: screen, gap: 10) == [
            1: rect(0, 0, 800 - 2 * p, 500), 2: rect(0, 0, 800 - 2 * p, 500),
            3: rect(p, 0, 800 - 2 * p, 500),
            4: rect(2 * p, 0, 800 - 2 * p, 500),
        ])
    }

    @Test func frontAtAnEndOnlyInsetsTowardTheOthers() {
        var layout = accordion(1, 2)
        layout.focus(1)
        let p = SpaceLayout.accordionPadding
        #expect(layout.frames(in: screen, gap: 0) == [1: rect(0, 0, 800 - p, 500), 2: rect(2 * p, 0, 800 - 2 * p, 500)])
    }

    @Test func fillIsUnchanged() {
        var layout = SpaceLayout(mode: .stack)
        layout.add(1, beside: nil, in: screen)
        layout.add(2, beside: 1, in: screen)
        layout.focus(2)
        #expect(layout.frames(in: screen, gap: 0) == [1: screen, 2: screen])
    }
}

@Suite struct AlgorithmSettings {
    @Test func defaultsAreBSPAndFill() {
        #expect(Settings.default.tileAlgorithm == .bsp)
        #expect(Settings.default.stackAlgorithm == .fill)
    }

    @Test func decodesFromConfig() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.default)) as! [String: Any]
        json["tiling"] = "master-stack"
        json["stacking"] = "accordion"
        let settings = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(settings.tileAlgorithm == .masterStack)
        #expect(settings.stackAlgorithm == .accordion)
    }
}
