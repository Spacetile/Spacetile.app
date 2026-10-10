import CryptoKit
import Foundation
import Testing
@testable import SpacetileCore

/// A moment as UTC ISO 8601, e.g. `at("2026-10-10T12:00:00Z")`.
private func at(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

private func base64URL<D: DataProtocol>(_ data: D) -> String {
    Data(data).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func payload(id: String, email: String, windowEnd: String, format: Int) -> Data {
    Data(#"{"format":\#(format),"id":"\#(id)","email":"\#(email)","windowEnd":"\#(windowEnd)","issued":"2026-10-01"}"#.utf8)
}

/// Signs keys with a throwaway Ed25519 key pair made for each test.
private struct Signer {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: Data { key.publicKey.rawRepresentation }

    func licenceKey(id: String = "lic_1", email: String = "ada@example.com", windowEnd: String = "2027-10-01", format: Int = 1) -> String {
        let bytes = payload(id: id, email: email, windowEnd: windowEnd, format: format)
        return base64URL(bytes) + "." + base64URL(try! key.signature(for: bytes))
    }
}

private let trialStart = at("2026-10-01T09:00:00Z")

@Suite struct Trial {
    let check = LicenceCheck(publicKey: Signer().publicKey, releaseDate: at("2026-10-01T00:00:00Z"), revokedLicences: [])

    @Test func startsWithFourteenDays() {
        #expect(check.entitlement(key: nil, trialStart: trialStart, now: trialStart) == .trial(daysLeft: 14))
    }

    @Test func countsDownADayAtATime() {
        #expect(check.entitlement(key: nil, trialStart: trialStart, now: at("2026-10-02T08:59:59Z")) == .trial(daysLeft: 14))
        #expect(check.entitlement(key: nil, trialStart: trialStart, now: at("2026-10-02T09:00:00Z")) == .trial(daysLeft: 13))
        #expect(check.entitlement(key: nil, trialStart: trialStart, now: at("2026-10-15T08:59:59Z")) == .trial(daysLeft: 1))
    }

    @Test func endsFourteenDaysAfterItStarts() {
        #expect(check.entitlement(key: nil, trialStart: trialStart, now: at("2026-10-15T09:00:00Z")) == .trialOver)
        #expect(check.entitlement(key: nil, trialStart: trialStart, now: at("2027-03-01T00:00:00Z")) == .trialOver)
    }

    @Test func aClockSetBeforeTheStartStillHasTheWholeTrial() {
        #expect(check.entitlement(key: nil, trialStart: trialStart, now: at("2026-09-01T00:00:00Z")) == .trial(daysLeft: 14))
    }

    @Test func noTrialStartMeansNoTrial() {
        #expect(check.entitlement(key: nil, trialStart: nil, now: trialStart) == .trialOver)
    }

    @Test func aBadKeyDoesNotCutTheTrialShort() {
        #expect(check.entitlement(key: "not a key", trialStart: trialStart, now: at("2026-10-05T09:00:00Z")) == .trial(daysLeft: 10))
    }
}

@Suite struct LicenceKeys {
    private let signer = Signer()
    let afterTrial = at("2026-11-01T00:00:00Z")

    func check(released: String = "2026-10-01T00:00:00Z", revoked: Set<String> = [], publicKey: Data? = nil) -> LicenceCheck {
        LicenceCheck(publicKey: publicKey ?? signer.publicKey, releaseDate: at(released), revokedLicences: revoked)
    }

    @Test func aValidKeyIsLicensedWithItsEmailAndUpdateWindowEnd() {
        let state = check().entitlement(key: signer.licenceKey(), trialStart: trialStart, now: afterTrial)
        guard case .licensed(let licence) = state else { Issue.record("expected Licensed, got \(state)"); return }
        #expect(licence.id == "lic_1")
        #expect(licence.email == "ada@example.com")
        #expect(licence.updateWindowEnd == at("2027-10-01T00:00:00Z"))
        #expect(licence.issued == at("2026-10-01T00:00:00Z"))
        #expect(state.isEntitled)
    }

    @Test func aValidKeyIsLicensedDuringTheTrialToo() {
        let state = check().entitlement(key: signer.licenceKey(), trialStart: trialStart, now: trialStart)
        #expect(state.licence?.email == "ada@example.com")
    }

    @Test func aPastedKeyMayHaveSurroundingWhitespace() {
        let state = check().entitlement(key: "  \(signer.licenceKey())\n", trialStart: trialStart, now: afterTrial)
        #expect(state.licence != nil)
    }

    @Test func aTamperedPayloadIsInvalid() {
        let parts = signer.licenceKey().split(separator: ".")
        let forged = base64URL(payload(id: "lic_1", email: "ada@example.com", windowEnd: "9999-12-31", format: 1)) + "." + parts[1]
        #expect(check().entitlement(key: forged, trialStart: trialStart, now: afterTrial) == .keyInvalid)
    }

    @Test func aKeySignedWithAnotherKeyIsInvalid() {
        let other = Signer()
        #expect(check().entitlement(key: other.licenceKey(), trialStart: trialStart, now: afterTrial) == .keyInvalid)
    }

    @Test(arguments: ["", "abc", "a.b", "a.b.c", ".", "!!!.???"])
    func malformedKeysAreInvalid(_ key: String) {
        #expect(check().entitlement(key: key, trialStart: trialStart, now: afterTrial) == .keyInvalid)
    }

    @Test func anUnknownFormatVersionIsInvalid() {
        #expect(check().entitlement(key: signer.licenceKey(format: 2), trialStart: trialStart, now: afterTrial) == .keyInvalid)
    }

    @Test func aMalformedWindowEndIsInvalid() {
        #expect(check().entitlement(key: signer.licenceKey(windowEnd: "2027-02-30"), trialStart: trialStart, now: afterTrial) == .keyInvalid)
    }

    @Test func noKeyAfterTheTrialIsTrialOver() {
        #expect(check().entitlement(key: nil, trialStart: trialStart, now: afterTrial) == .trialOver)
    }

    @Test func aBuildReleasedBeforeTheWindowEndIsLicensed() {
        let state = check(released: "2027-09-30T00:00:00Z").entitlement(key: signer.licenceKey(), trialStart: trialStart, now: afterTrial)
        #expect(state.isEntitled)
    }

    @Test func aBuildReleasedOnTheWindowEndIsLicensed() {
        let state = check(released: "2027-10-01T00:00:00Z").entitlement(key: signer.licenceKey(), trialStart: trialStart, now: afterTrial)
        #expect(state.isEntitled)
    }

    @Test func aBuildReleasedAfterTheWindowEndIsNotCovered() {
        let state = check(released: "2027-10-02T00:00:00Z").entitlement(key: signer.licenceKey(), trialStart: trialStart, now: afterTrial)
        guard case .updateWindowEnded(let licence) = state else { Issue.record("expected update window ended, got \(state)"); return }
        #expect(licence.id == "lic_1")
        #expect(state.licence == licence)
        #expect(!state.isEntitled)
    }

    @Test func aCoveredBuildKeepsWorkingLongAfterTheWindowCloses() {
        let state = check(released: "2027-09-30T00:00:00Z").entitlement(key: signer.licenceKey(), trialStart: trialStart, now: at("2031-01-01T00:00:00Z"))
        #expect(state.isEntitled)
    }

    @Test func aRevokedLicenceIsRevoked() {
        let state = check(revoked: ["lic_1"]).entitlement(key: signer.licenceKey(), trialStart: trialStart, now: afterTrial)
        #expect(state == .revoked)
        #expect(!state.isEntitled)
    }

    @Test func revokingAnotherLicenceLeavesThisOneLicensed() {
        let state = check(revoked: ["lic_2"]).entitlement(key: signer.licenceKey(), trialStart: trialStart, now: afterTrial)
        #expect(state.isEntitled)
    }

    @Test func aLifetimeWindowCoversFarFutureBuilds() {
        let state = check(released: "2090-06-01T00:00:00Z").entitlement(key: signer.licenceKey(windowEnd: "9999-12-31"), trialStart: trialStart, now: at("2090-06-02T00:00:00Z"))
        #expect(state.licence?.updateWindowEnd == at("9999-12-31T00:00:00Z"))
        #expect(state.isEntitled)
    }

    @Test func thePlaceholderPublicKeyVerifiesNothing() {
        let placeholder = check(publicKey: Data(count: 32))
        #expect(placeholder.entitlement(key: signer.licenceKey(), trialStart: trialStart, now: afterTrial) == .keyInvalid)
        let empty = check(publicKey: Data())
        #expect(empty.entitlement(key: signer.licenceKey(), trialStart: trialStart, now: afterTrial) == .keyInvalid)
    }

    @Test func aKeyCanBeReadOnItsOwn() {
        let licence = LicenceKey(verifying: signer.licenceKey(id: "lic_9"), publicKey: signer.publicKey)
        #expect(licence?.id == "lic_9")
        #expect(LicenceKey(verifying: Signer().licenceKey(), publicKey: signer.publicKey) == nil)
    }
}

@Suite struct TakingReleases {
    private let signer = Signer()
    var check: LicenceCheck { LicenceCheck(publicKey: signer.publicKey, releaseDate: at("2026-10-01T00:00:00Z"), revokedLicences: ["lic_revoked"]) }
    let afterTrial = at("2026-11-01T00:00:00Z")

    @Test func anyReleaseDuringTheTrial() {
        #expect(check.mayTake(releaseDated: at("2030-01-01T12:00:00Z"), key: nil, trialStart: trialStart, now: trialStart))
    }

    @Test func noReleaseAfterTheTrialWithoutAKey() {
        #expect(!check.mayTake(releaseDated: at("2026-10-20T12:00:00Z"), key: nil, trialStart: trialStart, now: afterTrial))
    }

    @Test func releasesUpToAndIncludingTheWindowEndDay() {
        let key = signer.licenceKey(windowEnd: "2027-10-01")
        #expect(check.mayTake(releaseDated: at("2027-09-30T23:00:00Z"), key: key, trialStart: trialStart, now: afterTrial))
        // The appcast's publish time can be any time of the window's last day
        #expect(check.mayTake(releaseDated: at("2027-10-01T23:59:59Z"), key: key, trialStart: trialStart, now: afterTrial))
        #expect(!check.mayTake(releaseDated: at("2027-10-02T00:00:00Z"), key: key, trialStart: trialStart, now: afterTrial))
    }

    @Test func aLifetimeWindowTakesEveryRelease() {
        #expect(check.mayTake(releaseDated: at("2095-01-01T00:00:00Z"), key: signer.licenceKey(windowEnd: "9999-12-31"), trialStart: trialStart, now: afterTrial))
    }

    @Test func aRevokedLicenceTakesNoRelease() {
        let key = signer.licenceKey(id: "lic_revoked")
        #expect(!check.mayTake(releaseDated: at("2026-12-01T00:00:00Z"), key: key, trialStart: trialStart, now: afterTrial))
    }

    @Test func anInvalidKeyTakesNoReleaseAfterTheTrial() {
        #expect(!check.mayTake(releaseDated: at("2026-12-01T00:00:00Z"), key: Signer().licenceKey(), trialStart: trialStart, now: afterTrial))
    }

    @Test func anUndatedReleaseOnlyDuringTheTrialOrWithALifetimeWindow() {
        #expect(check.mayTake(releaseDated: nil, key: nil, trialStart: trialStart, now: trialStart))
        #expect(!check.mayTake(releaseDated: nil, key: signer.licenceKey(windowEnd: "2099-12-31"), trialStart: trialStart, now: afterTrial))
        #expect(check.mayTake(releaseDated: nil, key: signer.licenceKey(windowEnd: "9999-12-31"), trialStart: trialStart, now: afterTrial))
    }
}

/// An appcast item, as far as the updater's choice goes.
struct Release: Equatable {
    let version: String
    let published: Date?
}

@Suite struct UpdateOffers {
    private let signer = Signer()
    var check: LicenceCheck { LicenceCheck(publicKey: signer.publicKey, releaseDate: at("2026-10-01T00:00:00Z"), revokedLicences: []) }
    let afterTrial = at("2027-12-01T00:00:00Z")
    /// Newest first, as the updater passes them: one after the window below ends, one inside it.
    let newer = [Release(version: "1.4", published: at("2027-11-01T10:00:00Z")),
                 Release(version: "1.3", published: at("2027-09-01T10:00:00Z"))]

    private func offer(_ releases: [Release], key: String?, now: Date) -> UpdateOffer<Release>? {
        check.offer(releases, published: \.published, key: key, trialStart: trialStart, now: now)
    }

    @Test func installsTheNewestReleaseTheWindowCovers() {
        let key = signer.licenceKey(windowEnd: "2027-10-01")
        #expect(offer(newer, key: key, now: afterTrial) == .install(Release(version: "1.3", published: at("2027-09-01T10:00:00Z"))))
    }

    @Test func installsAReleaseOnTheWindowEndDay() {
        let onTheDay = [Release(version: "1.3", published: at("2027-10-01T22:00:00Z"))]
        #expect(offer(onTheDay, key: signer.licenceKey(windowEnd: "2027-10-01"), now: afterTrial) == .install(onTheDay[0]))
    }

    @Test func marksTheNewestRenewToInstallWhenTheWindowCoversNone() {
        let key = signer.licenceKey(windowEnd: "2027-08-01")
        #expect(offer(newer, key: key, now: afterTrial) == .renewToInstall(newer[0]))
    }

    @Test func installsTheNewestReleaseDuringTheTrial() {
        #expect(offer(newer, key: nil, now: trialStart) == .install(newer[0]))
        #expect(offer(newer, key: signer.licenceKey(windowEnd: "2027-08-01"), now: trialStart) == .install(newer[0]))
    }

    @Test func offersNothingWithoutANewerRelease() {
        #expect(offer([], key: signer.licenceKey(), now: afterTrial) == nil)
    }
}

@Suite struct ReleaseDates {
    @Test func readsTheBundlesDayAsUTCMidnight() {
        #expect(Date(utcDay: "2026-10-10") == at("2026-10-10T00:00:00Z"))
    }

    @Test(arguments: ["", "2026-10", "2026-13-01", "2026-02-30", "26-10-10", "2026-10-10T00:00:00Z", "yyyy-mm-dd"])
    func rejectsAnythingElse(_ text: String) {
        #expect(Date(utcDay: text) == nil)
    }
}

@Suite struct EmbeddedRevocations {
    @Test func readsTheRevokedLicenceIDs() {
        let json = Data(#"{"revoked":["lic_0123456789abcdef01234567","lic_fedcba9876543210fedcba98"]}"#.utf8)
        #expect(Revocations.licenceIDs(in: json) == Set(["lic_0123456789abcdef01234567", "lic_fedcba9876543210fedcba98"]))
    }

    @Test func readsAnEmptyList() {
        #expect(Revocations.licenceIDs(in: Data(#"{"revoked":[]}"#.utf8)) == Set<String>())
    }

    @Test(arguments: ["", "<html>Bad gateway</html>", #"{"licences":[]}"#, #"{"revoked":"lic_1"}"#, #"{"revoked":[1]}"#])
    func refusesAnythingButTheList(_ json: String) {
        #expect(Revocations.licenceIDs(in: Data(json.utf8)) == nil)
    }

    @Test func aBuildCarryingAnIDRefusesThatKey() throws {
        let signer = Signer()
        let revoked = try #require(Revocations.licenceIDs(in: Data(#"{"revoked":["lic_1"]}"#.utf8)))
        let check = LicenceCheck(publicKey: signer.publicKey, releaseDate: at("2026-10-01T00:00:00Z"), revokedLicences: revoked)
        let afterTrial = at("2026-11-01T00:00:00Z")
        #expect(check.entitlement(key: signer.licenceKey(id: "lic_1"), trialStart: trialStart, now: afterTrial) == .revoked)
        #expect(check.entitlement(key: signer.licenceKey(id: "lic_2"), trialStart: trialStart, now: afterTrial).isEntitled)
    }
}
