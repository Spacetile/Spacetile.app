import Foundation
import Testing
@testable import SpacetileCore

@Suite struct EULAAcceptance {
    let defaults = UserDefaults(suiteName: "EULATests.\(UUID())")!

    @Test func aNewInstallHasNotAccepted() {
        #expect(!EULA.isAccepted(in: defaults))
    }

    @Test func acceptingRecordsTheVersionAndDate() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        EULA.accept(in: defaults, on: date)
        #expect(EULA.isAccepted(in: defaults))
        #expect(defaults.string(forKey: "eulaVersion") == EULA.version)
        #expect(defaults.object(forKey: "eulaAccepted") as? Date == date)
    }

    @Test func anEarlierVersionAsksAgain() {
        defaults.set("2026-01-01", forKey: "eulaVersion")
        #expect(!EULA.isAccepted(in: defaults))
    }
}
