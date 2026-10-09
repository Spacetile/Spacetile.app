import CoreGraphics
import Testing
@testable import SpacetileCore

private func ref(_ app: String, _ index: Int = 0) -> WindowRef { WindowRef(app: app, index: index) }
private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

@Suite struct ProfileDesigner {
    let mainAndStack = LayoutSnapshot.templates.first { $0.name == "Main + stack" }!.layout

    @Test func tilesCarryPathsAndRects() {
        let tiles = mainAndStack.tiles(in: unit, gap: 0)
        #expect(tiles.map(\.path) == [[false], [true, false], [true, true]])
        #expect(tiles[2].rect == CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    @Test func dividersSitBetweenChildren() {
        let dividers = mainAndStack.dividers(in: unit, gap: 4)
        #expect(dividers.map(\.path) == [[], [true]])
        #expect(dividers[0].axis == .horizontal)
        #expect(dividers[0].strip == CGRect(x: 48, y: 0, width: 4, height: 100))
    }

    @Test func splitKeepsWindowsInTheFirstHalf() {
        let layout = LayoutSnapshot.tile([ref("a")]).splitting(at: [], along: .vertical)
        #expect(layout == .split(axis: .vertical, ratio: 0.5, first: .tile([ref("a")]), second: .tile([])))
    }

    @Test func removingATileGivesItsSiblingTheSpace() {
        #expect(mainAndStack.removing(at: [true, false]) == .split(axis: .horizontal, ratio: 0.5, first: .tile([]), second: .tile([])))
        #expect(LayoutSnapshot.tile([ref("a")]).removing(at: []) == .tile([]))
    }

    @Test func ratioIsClamped() {
        #expect(mainAndStack.settingRatio(at: [], to: 0.99).dividers(in: unit, gap: 0)[0].strip.minX == 90)
    }

    @Test func templatesFillWithExistingWindowsInOrder() {
        let filled = mainAndStack.filled(with: [ref("a"), ref("b"), ref("c"), ref("d")])
        #expect(filled.tiles(in: unit, gap: 0).map(\.refs) == [[ref("a")], [ref("b")], [ref("c"), ref("d")]])
    }

    @Test func renumberingCountsEachAppsWindowsInReadingOrder() {
        let profile = Profile(name: "p", display: nil, spaces: [
            SpaceSnapshot(space: 3, mode: .bsp, tree: .tile([ref("chrome", 5)]), floating: [], others: []),
            SpaceSnapshot(space: 1, mode: .bsp, tree: .split(axis: .horizontal, ratio: 0.5, first: .tile([ref("chrome", 9)]), second: .tile([ref("zed", 2)])),
                          floating: [ref("chrome", 0)], others: []),
        ]).renumbered()
        #expect(profile.spaces.map(\.space) == [1, 3])
        #expect(profile.spaces[0].windows == [ref("chrome", 0), ref("zed", 0), ref("chrome", 1)])
        #expect(profile.spaces[1].windows == [ref("chrome", 2)])
    }
}

@Suite struct ProfileNames {
    @Test func freeNameIsKept() {
        #expect(uniqueProfileName("meeting copy", taken: ["meeting"]) == "meeting copy")
    }

    @Test func takenNamesGetTheNextNumber() {
        #expect(uniqueProfileName("Untitled", taken: ["Untitled", "Untitled 2"]) == "Untitled 3")
    }

    let taken: Set<String> = ["work", "a-b"]

    @Test func acceptsAFreeName() { #expect(profileNameProblem("home", taken: taken) == nil) }
    @Test func rejectsBlank() { #expect(profileNameProblem("  ", taken: taken) == "Enter a name.") }
    @Test func rejectsATakenName() { #expect(profileNameProblem("work", taken: taken) == "A profile called “work” already exists.") }
    @Test func letsARenameKeepItsName() { #expect(profileNameProblem("work", current: "work", taken: taken) == nil) }
    @Test func rejectsANameThatSharesAFile() { #expect(profileNameProblem("a/b", taken: taken) == "“a/b” would share a file with “a-b”.") }
    @Test func rejectsANameDifferingOnlyByCase() { #expect(profileNameProblem("Work", taken: taken) == "“Work” would share a file with “work”.") }
    @Test func letsARenameChangeCase() { #expect(profileNameProblem("Work", current: "work", taken: taken) == nil) }
    @Test func rejectsANameTooLongForAFile() {
        #expect(profileNameProblem(String(repeating: "x", count: 250), taken: taken) == nil)
        #expect(profileNameProblem(String(repeating: "x", count: 251), taken: taken) == "That name is too long.")
    }
}
