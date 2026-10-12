import Foundation
import Testing
@testable import SpacetileCore

/// Keys the licence service's tests sign with a fixed test key pair and write to Fixtures/. When the
/// service's key format drifts from what the app reads, they stop verifying here.
private struct Fixtures: Decodable {
    struct Key: Decodable {
        let name: String
        let id: String
        let email: String
        let windowEnd: String
        let issued: String
        let key: String
    }

    let publicKey: String
    let keys: [Key]

    static func load() throws -> Fixtures {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(components: "Fixtures", "licence-keys.json")
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

@Suite struct LicenceServiceKeys {
    @Test func verifyWithTheFieldsTheyWereSignedWith() throws {
        let fixtures = try Fixtures.load()
        let publicKey = try #require(Data(base64Encoded: fixtures.publicKey))
        try #require(!fixtures.keys.isEmpty)
        for fixture in fixtures.keys {
            let licence = try #require(LicenceKey(verifying: fixture.key, publicKey: publicKey), "\(fixture.name) doesn't verify")
            #expect(licence.format == 1, "\(fixture.name)")
            #expect(licence.id == fixture.id, "\(fixture.name)")
            #expect(licence.email == fixture.email, "\(fixture.name)")
            #expect(licence.updateWindowEnd == Date(utcDay: fixture.windowEnd), "\(fixture.name)")
            #expect(licence.issued == Date(utcDay: fixture.issued), "\(fixture.name)")
        }
    }

    @Test func licenseABuildReleasedOnTheirWindowEnd() throws {
        let fixtures = try Fixtures.load()
        let publicKey = try #require(Data(base64Encoded: fixtures.publicKey))
        for fixture in fixtures.keys {
            let released = try #require(Date(utcDay: fixture.windowEnd))
            let check = LicenceCheck(publicKey: publicKey, coverage: .windowOpenOn(released), revokedLicences: [])
            let state = check.entitlement(key: fixture.key, trialStart: nil, now: released)
            #expect(state.licence?.id == fixture.id && state.isEntitled, "\(fixture.name): \(state)")
        }
    }
}
