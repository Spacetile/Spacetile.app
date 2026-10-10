import Testing
@testable import SpacetileCore

@Suite struct LicenceGates {
    @Test(arguments: ["1.0.0", "1.0.0-beta.1", "1.0.0-nightly.20270101", "1.2.1-nightly.20270315", "2.0.0", "10.4.2"])
    func releasesFromOnePointOhHaveTheGate(_ version: String) {
        #expect(LicenceGate.applies(toVersion: version, released: true))
    }

    @Test(arguments: ["0.1.0", "0.9.3", "0.1.0-nightly.20261010", "0.9.4-beta.2"])
    func releasesBeforeOnePointOhHaveNoGate(_ version: String) {
        #expect(!LicenceGate.applies(toVersion: version, released: true))
    }

    @Test(arguments: ["0.1.0", "1.0.0", "", "local"])
    func localBuildsHaveTheGateWhateverTheirVersion(_ version: String) {
        #expect(LicenceGate.applies(toVersion: version, released: false))
    }

    @Test(arguments: [nil, "", "v0.9.0", "beta", ".1.0"] as [String?])
    func aReleaseWithoutAReadableVersionHasTheGate(_ version: String?) {
        #expect(LicenceGate.applies(toVersion: version, released: true))
    }
}
