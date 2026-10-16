import Foundation
import Testing
@testable import SpacetileCore

@Suite struct Sessions {
    private let notes = WindowRef(app: "notes", index: 0)
    private let mail = WindowRef(app: "mail", index: 0)
    private let zed = WindowRef(app: "zed", index: 0)

    /// Notes | (Mail / Zed) at 0.7, as left before the relaunch.
    private var saved: Session.Space {
        let tree = LayoutSnapshot.split(axis: .horizontal, ratio: 0.7, first: .tile([notes]),
                                        second: .split(axis: .vertical, ratio: 0.4, first: .tile([mail]), second: .tile([zed])))
        return Session.Space(id: 7, layout: SpaceSnapshot(space: 1, mode: .bsp, tree: tree, floating: [], others: []),
                             windows: [notes: 10, mail: 20, zed: 30], configuredMode: .bsp)
    }

    private func restorable(mode: LayoutMode = .bsp, isHere: (WindowID, String) -> Bool = { _, _ in true },
                            floats: (WindowID) -> Bool = { _ in false }) -> (layout: SpaceSnapshot, windows: [WindowRef: WindowID])? {
        saved.restorable(mode: mode, isHere: isHere, floats: floats)
    }

    @Test func windowsStillOpenGetTheirTilesBackAndClosedOnesLeaveNoGap() throws {
        // Mail closed while Spacetile wasn't running
        let (layout, windows) = try #require(restorable(isHere: { id, _ in id != 20 }))
        #expect(windows == [notes: 10, zed: 30])
        let restored = SpaceLayout(snapshot: layout) { windows[$0] }
        #expect(restored.tree.root == .split(axis: .horizontal, ratio: 0.7, first: .leaf(10), second: .leaf(30)))
        #expect(restored.tree.holes.isEmpty)
    }

    @Test func aWindowNumberNowUsedByAnotherAppDoesntMatch() {
        #expect(restorable(isHere: { _, app in app == "safari" }) == nil)
    }

    @Test func settingsChangedWhileNotRunningWin() throws {
        // config.json now makes the Space a Stack Space, and a new rule floats Zed
        let (layout, _) = try #require(restorable(mode: .stack, floats: { $0 == 30 }))
        #expect(layout.mode == .stack)
        #expect(layout.floating == [zed])
        #expect(layout.tree == .split(axis: .horizontal, ratio: 0.7, first: .tile([notes]), second: .tile([mail])))
    }

    @Test func aModeChosenWhileRunningStays() throws {
        var space = saved
        space.layout.mode = .stack
        let (layout, _) = try #require(space.restorable(mode: .bsp, isHere: { _, _ in true }, floats: { _ in false }))
        #expect(layout.mode == .stack)
    }

    @Test func roundTripsThroughJSON() throws {
        let session = Session(boot: 1_760_000_000, windowServer: 412, spaces: [saved])
        #expect(try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session)) == session)
    }
}
