import Foundation
import CoreGraphics
import Testing
@testable import SpacetileCore

/// A laptop on the left, a studio display on the right; the studio display has the menu bar.
private let laptop = DisplaySpaces(id: "L", identity: DisplayIdentity(name: "Built-in Retina Display", vendor: 1552, model: 41054, serial: 4251086178, builtIn: true), frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   spaces: [1, 2, 3], current: 2)
private let studio = DisplaySpaces(id: "S", identity: DisplayIdentity(name: "Studio Display", vendor: 1552, model: 44602, serial: 3059903073), frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                   spaces: [10, 11], current: 10)
private let both = Desktops(displays: [studio, laptop], activeID: "S")

@Suite struct DesktopNumbering {
    @Test func numbersCountWithinEachDisplay() {
        #expect(both.number(of: 3) == 3)
        #expect(both.number(of: 11) == 2)
        #expect(both.number(of: 99) == nil)
    }

    @Test func numberedSpacesComeFromTheActiveDisplay() {
        #expect(both.activeSpace == 10)
        #expect(both.space(number: 2, on: both.active!) == 11)
        #expect(both.space(number: 3, on: both.active!) == nil)
    }

    @Test func everyDisplayShowsOneSpace() { #expect(both.visible == [2, 10]) }

    @Test func activeFallsBackToTheFirstDisplay() { #expect(Desktops(displays: [studio, laptop], activeID: nil).active == laptop) }
}

@Suite struct DisplayOrder {
    @Test func displaysRunLeftToRight() { #expect(both.displays == [laptop, studio]) }

    @Test func nextAndPreviousWrap() {
        #expect(both.neighbor(of: studio, forward: true) == laptop)
        #expect(both.neighbor(of: laptop, forward: false) == studio)
    }

    @Test func oneDisplayHasNoNeighbour() {
        #expect(Desktops(displays: [laptop], activeID: "L").neighbor(of: laptop, forward: true) == nil)
    }

    @Test func onlyOuterEdgesCount() {
        #expect(both.isOuterEdge(right: false, of: laptop))
        #expect(!both.isOuterEdge(right: true, of: laptop))
        #expect(!both.isOuterEdge(right: false, of: studio))
        #expect(both.isOuterEdge(right: true, of: studio))
    }
}

@Suite struct ProfileDisplays {
    @Test func oneDisplayIsJustItsName() {
        #expect(Desktops(displays: [laptop], activeID: "L").fingerprint == "Built-in Retina Display")
    }

    @Test func severalAreSortedAndJoined() { #expect(both.fingerprint == "Built-in Retina Display + Studio Display") }

    /// Profiles from before multi-display have no display on their Spaces: they go to the main
    /// display, wherever focus is.
    @Test func olderSnapshotsGoToTheMainDisplay() {
        let studio = DisplaySpaces(id: "S", identity: studio.identity, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), spaces: Array(1...10), current: 1)
        let laptop = DisplaySpaces(id: "L", identity: laptop.identity, frame: CGRect(x: 2560, y: 1180, width: 1512, height: 982), spaces: [15, 28, 29], current: 15)
        let older = Profile(name: "p", display: nil, spaces: [SpaceSnapshot(space: 6, mode: .bsp, tree: nil, floating: [], others: [], display: nil)])
        let placed = Desktops(displays: [studio, laptop], activeID: "L").place(older)
        #expect(placed.map(\.space) == [6])
        #expect(placed[0].reason == .matched)
    }
}

@Suite struct SnapshotDisplay {
    @Test func olderProfilesDecodeWithoutADisplay() throws {
        let json = #"{"space": 2, "floating": ["com.apple.Safari#0"]}"#
        let snapshot = try JSONDecoder().decode(SpaceSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.space == 2)
        #expect(snapshot.display == nil)
    }

    @Test func theDisplayRoundTrips() throws {
        let snapshot = SpaceSnapshot(space: 1, mode: .bsp, tree: nil, floating: [], others: [], display: "Studio Display")
        #expect(try JSONDecoder().decode(SpaceSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }
}

@Suite struct DisplayMatching {
    let studioID = DisplayIdentity(name: "Studio Display", vendor: 1552, model: 44602, serial: 3059903073)
    let laptopID = DisplayIdentity(name: "Built-in Retina Display", vendor: 1552, model: 41054, serial: 4251086178, builtIn: true)

    @Test func signaturesUseVendorModelSerial() { #expect(studioID.signature == "1552-44602-3059903073") }

    @Test func noSerialFallsBackToTheName() { #expect(DisplayIdentity(name: "Projector", vendor: 1, model: 2).signature == "Projector") }

    @Test func sameDisplaysMatchBySignature() {
        let assigned = both.assign([studioID, laptopID])
        #expect(assigned[studioID.signature] == studio)
        #expect(assigned[laptopID.signature] == laptop)
    }

    /// Renamed by a language change: the signature still finds it.
    @Test func signaturesSurviveARename() {
        var renamed = studioID
        renamed.name = "Écran Studio"
        #expect(both.assign([renamed])[renamed.signature] == studio)
    }

    /// Another Studio Display, e.g. at a different desk: same name, different serial.
    @Test func aDifferentUnitMatchesByName() {
        let other = DisplayIdentity(name: "Studio Display", vendor: 1552, model: 44602, serial: 1)
        #expect(both.assign([other])[other.signature] == studio)
    }

    /// A different monitor altogether falls back to its role: external for external.
    @Test func otherwiseRolesMatch() {
        let projector = DisplayIdentity(name: "Projector", vendor: 9, model: 9, serial: 9)
        let otherLaptop = DisplayIdentity(name: "Color LCD", vendor: 9, model: 8, serial: 7, builtIn: true)
        let assigned = both.assign([projector, otherLaptop])
        #expect(assigned[projector.signature] == studio)
        #expect(assigned[otherLaptop.signature] == laptop)
    }

    /// Two identical monitors share a name, so each recorded one needs its own connected one.
    @Test func eachConnectedDisplayIsUsedOnce() {
        let twin = DisplayIdentity(name: "Studio Display", vendor: 1552, model: 44602, serial: 2)
        let assigned = both.assign([studioID, twin])
        #expect(assigned[studioID.signature] == studio)
        #expect(assigned[twin.signature] == nil)
    }

    @Test func olderProfilesNameTheirDisplays() {
        let space = SpaceSnapshot(space: 1, mode: .bsp, tree: nil, floating: [], others: [], display: "Studio Display")
        #expect(Profile(name: "p", display: nil, spaces: [space]).recordedDisplays == [DisplayIdentity(name: "Studio Display")])
    }
}

@Suite struct ProfilePlacing {
    let studioID = DisplayIdentity(name: "Studio Display", vendor: 1552, model: 44602, serial: 3059903073)
    let laptopID = DisplayIdentity(name: "Built-in Retina Display", vendor: 1552, model: 41054, serial: 4251086178, builtIn: true)

    /// Captured on the studio (main, 3 Desktops) and laptop (2 Desktops).
    var captured: Profile {
        let spaces = [SpaceSnapshot(space: 1, mode: .bsp, tree: nil, floating: [], others: [], display: studioID.signature),
                      SpaceSnapshot(space: 3, mode: .bsp, tree: nil, floating: [], others: [], display: studioID.signature),
                      SpaceSnapshot(space: 2, mode: .bsp, tree: nil, floating: [], others: [], display: laptopID.signature)]
        return Profile(name: "p", display: nil,
                       displays: [ProfileDisplay(identity: studioID, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), desktops: 3),
                                  ProfileDisplay(identity: laptopID, frame: CGRect(x: 1048, y: 1440, width: 1512, height: 982), desktops: 2)],
                       spaces: spaces)
    }

    /// The laptop alone, as main, after macOS appended the studio's 3 Desktops to its own 2.
    func laptopAlone(desktops: Int) -> Desktops {
        Desktops(displays: [DisplaySpaces(id: "L", identity: laptopID, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                          spaces: Array(100..<(100 + desktops)), current: 100)], activeID: "L")
    }

    @Test func everyDisplayConnectedMatches() {
        let studio = DisplaySpaces(id: "S", identity: studioID, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), spaces: [1, 2, 3], current: 1)
        let laptop = DisplaySpaces(id: "L", identity: laptopID, frame: CGRect(x: 1048, y: 1440, width: 1512, height: 982), spaces: [7, 8], current: 7)
        let placed = Desktops(displays: [studio, laptop], activeID: "S").place(captured)
        #expect(placed.map(\.space) == [1, 3, 8])
        #expect(placed.allSatisfy { $0.reason == .matched })
    }

    @Test func aMissingDisplayIsAppendedLikeMacOSDoes() {
        let placed = laptopAlone(desktops: 5).place(captured)
        // The studio's Desktops 1 and 3 come after the laptop's own 2: Desktops 3 and 5
        #expect(placed.map(\.number) == [3, 5, 2])
        #expect(placed[0].reason == .appended(onto: "Built-in Retina Display"))
        #expect(placed[2].reason == .matched)
    }

    @Test func desktopsThatDontExistAreNotPlaced() {
        let placed = laptopAlone(desktops: 2).place(captured)
        #expect(placed[1].space == nil)
        #expect(placed[1].reason == .noRoom)
    }

    @Test func exactMatchNeedsTheSameDisplays() {
        #expect(!laptopAlone(desktops: 5).matchesExactly(captured))
        var laptopOnly = captured
        laptopOnly.displays = [ProfileDisplay(identity: laptopID, frame: .zero, desktops: 2)]
        #expect(laptopAlone(desktops: 5).matchesExactly(laptopOnly))
    }

    /// Older profiles name a single display; it must be connected alone.
    @Test func olderProfilesMatchByName() {
        let older = Profile(name: "laptop", display: "Built-in Retina Display", spaces: [])
        #expect(laptopAlone(desktops: 5).matchesExactly(older))
    }
}

@Suite struct DisplayArrangement {
    let studio = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let laptopBelow = CGRect(x: 1048, y: 1440, width: 1512, height: 982)
    let laptopBeside = CGRect(x: 2560, y: 400, width: 1512, height: 982)

    @Test func stackedDisplaysTakeARowEach() { #expect(Arrangement.rows([laptopBelow, studio]) == [[1], [0]]) }

    @Test func sideBySideDisplaysShareARow() { #expect(Arrangement.rows([laptopBeside, studio]) == [[1, 0]]) }

    @Test func fittingKeepsPositionsAndProportions() {
        let box = CGSize(width: 300, height: 300)
        let fitted = Arrangement.fit([studio, laptopBelow], in: box)
        #expect(abs(fitted[0].width / fitted[0].height - studio.width / studio.height) < 0.001)
        #expect(abs(fitted[1].minY - fitted[0].maxY) < 0.001)
        #expect(fitted.allSatisfy { CGRect(origin: .zero, size: box).insetBy(dx: -0.001, dy: -0.001).contains($0) })
    }
}

@Suite struct SpanningDisplays {
    let studioID = DisplayIdentity(name: "Studio Display", vendor: 1552, model: 44602, serial: 3059903073)
    let laptopID = DisplayIdentity(name: "Built-in Retina Display", vendor: 1552, model: 41054, serial: 4251086178, builtIn: true)

    /// The probe's setup: one set of Spaces (1, 5, 6), the studio above the laptop, Desktop 2 showing.
    var spanning: Desktops {
        .spanning(screens: [(id: "L", identity: laptopID, frame: CGRect(x: 1048, y: 1440, width: 1512, height: 982), index: 1),
                            (id: "S", identity: studioID, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), index: 0)],
                  spaces: [1, 5, 6], current: 5)
    }

    @Test func idsRoundTrip() {
        let id = SpanningSpace.id(space: 5, display: 1)
        #expect(SpanningSpace.decode(id)! == (space: 5, display: 1))
    }

    @Test func realIDsAreNotSpanningIDs() { #expect(SpanningSpace.decode(16) == nil) }

    @Test func eachDisplayGetsTheSharedDesktops() {
        let desktops = spanning
        #expect(desktops.spansDisplays)
        #expect(desktops.displays.map(\.spaces.count) == [3, 3])
        let studio = desktops.displays[0], laptop = desktops.displays[1]
        #expect(Set(studio.spaces).isDisjoint(with: laptop.spaces))
        #expect(desktops.real(studio.current) == 5 && desktops.real(laptop.current) == 5)
    }

    @Test func numbersMatchAcrossDisplays() {
        let desktops = spanning
        #expect(desktops.number(of: desktops.displays[0].spaces[2]) == 3)
        #expect(desktops.number(of: desktops.displays[1].spaces[2]) == 3)
        #expect(desktops.display(of: desktops.displays[1].spaces[0]) == desktops.displays[1])
    }

    @Test func theMainDisplayIsActive() { #expect(spanning.active?.id == "S") }

    @Test func displaysStillHaveNeighbours() {
        let desktops = spanning
        #expect(desktops.neighbor(of: desktops.displays[0], forward: true) == desktops.displays[1])
    }

    /// A full-screen app's Space isn't a Desktop: it has no number on any display.
    @Test func unknownSpacesHaveNoNumber() { #expect(spanning.number(of: SpanningSpace.id(space: 99, display: 0)) == nil) }

    @Test func autoApplyNeedsTheSameMode() {
        let both = [ProfileDisplay(identity: studioID, frame: .zero, desktops: 3), ProfileDisplay(identity: laptopID, frame: .zero, desktops: 3)]
        let separate = Profile(name: "p", display: nil, displays: both, spaces: [])
        let captured = Profile(name: "p", display: nil, displays: both, spansDisplays: true, spaces: [])
        #expect(!spanning.matchesExactly(separate))
        #expect(spanning.matchesExactly(captured))
    }

    @Test func profilesPlacePerDisplay() {
        let spaces = [SpaceSnapshot(space: 2, mode: .bsp, tree: nil, floating: [], others: [], display: laptopID.signature)]
        let profile = Profile(name: "p", display: nil, displays: [ProfileDisplay(identity: laptopID, frame: .zero, desktops: 3)], spaces: spaces)
        let placed = spanning.place(profile)
        #expect(placed[0].space == spanning.displays[1].spaces[1])
    }
}

@Suite struct DisplayReturning {
    private let alone = Desktops(displays: [laptop], activeID: "L")

    @Test func returningDisplayGetsItsLayoutsBack() {
        var departed = DepartedLayouts()
        let arranged = [10: layout(1, 2, 3), 2: layout(4)]
        #expect(departed.update(from: both, to: alone, layouts: arranged).isEmpty)
        // Its windows went to the laptop meanwhile, emptying the studio display's layout
        let back = departed.update(from: alone, to: both, layouts: [10: SpaceLayout(), 2: layout(4, 1, 2, 3)])
        #expect(back == [10: arranged[10]!])
    }

    @Test func layoutsRearrangedMeanwhileStay() {
        var departed = DepartedLayouts()
        _ = departed.update(from: both, to: alone, layouts: [10: layout(1, 2)])
        #expect(departed.update(from: alone, to: both, layouts: [10: layout(5)]).isEmpty)
    }
}
