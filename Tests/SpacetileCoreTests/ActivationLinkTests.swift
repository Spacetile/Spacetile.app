import Foundation
import Testing
@testable import SpacetileCore

@Suite struct ActivationLinks {
    @Test func carryTheirKey() throws {
        let url = try #require(URL(string: "spacetile://activate?key=eyJmb3JtYXQiOjF9.c2lnbmF0dXJl-_"))
        #expect(ActivationLink.key(in: url) == "eyJmb3JtYXQiOjF9.c2lnbmF0dXJl-_")
    }

    @Test func decodePercentEscapes() throws {
        let url = try #require(URL(string: "spacetile://activate?key=abc%2Edef"))
        #expect(ActivationLink.key(in: url) == "abc.def")
    }

    @Test(arguments: [
        "spacetile://settings?key=abc",
        "https://activate?key=abc",
        "spacetile://activate",
        "spacetile://activate?key=",
        "spacetile://activate?licence=abc",
    ])
    func refuseEverythingElse(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(ActivationLink.key(in: url) == nil)
    }
}
