import CoreGraphics
import Foundation
import Testing
@testable import SpacetileCore

@Suite struct Profiles {
    @Test func refsNumberEachAppsWindowsInCreationOrder() {
        let refs = WindowRef.assign([(30, "zed"), (10, "chrome"), (20, "chrome")])
        #expect(refs[10] == WindowRef(app: "chrome", index: 0))
        #expect(refs[20] == WindowRef(app: "chrome", index: 1))
        #expect(refs[30] == WindowRef(app: "zed", index: 0))
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        var l = layout(1, 2, 3)
        l.toggleFloat(3, beside: 2, in: screen)
        let names: [WindowID: WindowRef] = [1: .init(app: "a", index: 0), 2: .init(app: "b", index: 0), 3: .init(app: "b", index: 1)]
        let profile = Profile(name: "test", display: "Studio Display",
                              spaces: [l.snapshot(space: 3, ref: { names[$0] })])
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)

        // New window numbers, same apps: the layout comes back with the new numbers
        let live: [WindowRef: WindowID] = [names[1]!: 101, names[2]!: 102, names[3]!: 103]
        let restored = SpaceLayout(snapshot: decoded.spaces[0], resolve: { live[$0] })
        #expect(restored.tree.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(101), second: .leaf(102)))
        #expect(restored.floating == [103])
    }

    @Test func jsonIsCompactAndHandEditable() throws {
        let json = #"{"axis": "horizontal", "ratio": 0.6, "first": ["com.google.Chrome#0"], "second": ["dev.zed.Zed#0", "com.google.Chrome#1"]}"#
        let tree = try JSONDecoder().decode(LayoutSnapshot.self, from: Data(json.utf8))
        #expect(tree == .split(axis: .horizontal, ratio: 0.6, first: .tile([.init(app: "com.google.Chrome", index: 0)]),
                               second: .tile([.init(app: "dev.zed.Zed", index: 0), .init(app: "com.google.Chrome", index: 1)])))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WindowRef.self, from: Data(#""no-index""#.utf8)) }
    }

    @Test func iconRoundTripsAndDefaultsWhenAbsent() throws {
        var profile = Profile(name: "work", display: nil, spaces: [])
        #expect(profile.icon == nil)
        profile.setIcon("briefcase")
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.icon == "briefcase")
        // Choosing the default stores nothing, so files without an icon stay as they were
        profile.setIcon(Profile.defaultIcon)
        #expect(profile.icon == nil)
        #expect(!String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).contains("icon"))
    }

    @Test func iconChoicesStartWithTheDefaultAndDontRepeat() {
        let symbols = Profile.iconChoices.flatMap(\.icons).map(\.symbol)
        #expect(symbols.first == Profile.defaultIcon)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test func handWrittenProfileNeedsOnlyTheEssentials() throws {
        let json = #"{"name": "meeting", "show": 5, "spaces": [{"space": 5, "tree": {"axis": "horizontal", "ratio": 0.5, "first": ["md.obsidian#0"], "second": ["com.google.Chrome#0"]}}]}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(profile.show == 5)
        #expect(profile.spaces[0].mode == .bsp)
        #expect(profile.spaces[0].floating.isEmpty)
        #expect(profile.apps == ["md.obsidian", "com.google.Chrome"])
    }

    /// Notes | (Reminders / Calendar), with only Notes open so far.
    private func waitingForTwo() -> SpaceLayout {
        let tree = LayoutSnapshot.split(axis: .horizontal, ratio: 0.5, first: .tile([.init(app: "notes", index: 0)]),
                                        second: .split(axis: .vertical, ratio: 0.5, first: .tile([.init(app: "reminders", index: 0)]),
                                                       second: .tile([.init(app: "calendar", index: 0)])))
        let snapshot = SpaceSnapshot(space: 1, mode: .bsp, tree: tree, floating: [], others: [])
        return SpaceLayout(snapshot: snapshot) { $0.app == "notes" ? 1 : nil }
    }

    @Test func missingWindowsKeepTheirPlace() {
        let restored = waitingForTwo()
        #expect(restored.tree.windows == [1])
        #expect(restored.tree.holes.count == 2)
        #expect(Set(restored.waiting.values) == ["reminders", "calendar"])
    }

    @Test func eachAppFillsItsOwnTile() {
        var restored = waitingForTwo()
        // Calendar arrives first, but still takes the bottom-right tile
        restored.add(3, app: "calendar", beside: 1, in: screen)
        restored.add(2, app: "reminders", beside: 3, in: screen)
        #expect(restored.tree.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1),
                                             second: .split(axis: .vertical, ratio: 0.5, first: .leaf(2), second: .leaf(3))))
        #expect(restored.waiting.isEmpty)
    }

    @Test func otherAppsLeaveWaitingTilesAlone() {
        var restored = waitingForTwo()
        restored.add(9, app: "slack", beside: 1, in: screen)
        #expect(restored.tree.windows.contains(9))
        #expect(restored.waiting.count == 2)
    }

    @Test func aSpaceOfOnlyWaitingTilesSplitsForOtherApps() {
        let snapshot = SpaceSnapshot(space: 1, mode: .bsp, tree: .tile([.init(app: "notes", index: 0)]), floating: [], others: [])
        var restored = SpaceLayout(snapshot: snapshot) { _ in nil }
        restored.add(9, app: "slack", beside: nil, in: screen)
        #expect(restored.tree.windows == [9])
        #expect(restored.waiting.count == 1)
        restored.add(1, app: "notes", beside: nil, in: screen)
        #expect(Set(restored.tree.windows) == [1, 9])
        #expect(restored.tree.holes.isEmpty)
    }

    @Test func profileListsEveryPlacedApp() {
        let space = SpaceSnapshot(space: 1, mode: .bsp, tree: .tile([.init(app: "a", index: 0)]),
                                      floating: [.init(app: "b", index: 0)], others: [.init(app: "c", index: 0)])
        #expect(Profile(name: "p", display: nil, spaces: [space]).apps == ["a", "b", "c"])
    }

    @Test func launchItemsAreReadFromHowTheyStart() {
        #expect(LaunchItem("https://github.com") == .link("https://github.com"))
        #expect(LaunchItem("mailto:me@example.com") == .link("mailto:me@example.com"))
        #expect(LaunchItem("github.com/Spacetile") == .link("https://github.com/Spacetile"))
        #expect(LaunchItem("localhost:3000") == .link("https://localhost:3000"))
        #expect(LaunchItem("~/code/spacetile") == .path("~/code/spacetile"))
        #expect(LaunchItem("/Users/me/notes.md") == .path("/Users/me/notes.md"))
        #expect(LaunchItem("$ cd ~/code && make") == .command("cd ~/code && make"))
        #expect(LaunchItem("  ") == nil)
        #expect(LaunchItem("$") == nil)
    }

    @Test func appsOnlyOpenedInAreLaunchedToo() {
        let space = SpaceSnapshot(space: 1, mode: .bsp, tree: .tile([.init(app: "chrome", index: 0)]), floating: [], others: [])
        var profile = Profile(name: "p", display: nil, spaces: [space])
        profile.setItems(["$ npm run dev"], opening: "terminal")
        profile.setItems(["  ", ""], opening: "zed")
        #expect(profile.apps == ["chrome"])
        #expect(profile.launchedApps == ["chrome", "terminal"])
        #expect(profile.items(opening: "terminal") == [.command("npm run dev")])
        #expect(profile.items(opening: "chrome").isEmpty)
    }

    @Test func blankItemsDropTheField() throws {
        var profile = Profile(name: "p", display: nil, spaces: [])
        profile.setItems(["github.com", "", " ~/code "], opening: "chrome")
        #expect(profile.open == ["chrome": ["github.com", "~/code"]])
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        profile.setItems([""], opening: "chrome")
        #expect(profile.open == nil)
    }
}
