import CryptoKit
import Foundation

/// What an install may do, decided offline from its Licence key and Trial (ADR 0001).
public enum Entitlement: Equatable, Sendable {
    /// Inside the 14-day Trial, with `daysLeft` from 14 down to 1.
    case trial(daysLeft: Int)
    /// A valid Licence key whose update window covers this build.
    case licensed(LicenceKey)
    /// The Trial has ended and there's no Licence key.
    case trialOver
    /// The Trial has ended and the key doesn't verify: tampered, signed with another key, malformed
    /// or in a format this build doesn't know.
    case keyInvalid
    /// The Trial has ended and the key's Licence is in this build's revoked list.
    case revoked
    /// The Trial has ended and the key is valid, but this build was released after its update window
    /// closed. Renewing covers it.
    case updateWindowEnded(LicenceKey)

    /// Tiling and profiles run: in the Trial or Licensed.
    public var isEntitled: Bool {
        switch self {
        case .trial, .licensed: true
        case .trialOver, .keyInvalid, .revoked, .updateWindowEnded: false
        }
    }

    /// The verified key, when there is one this build accepts or one it would accept after a Renewal.
    public var licence: LicenceKey? {
        switch self {
        case .licensed(let licence), .updateWindowEnded(let licence): licence
        case .trial, .trialOver, .keyInvalid, .revoked: nil
        }
    }
}

/// The release the updater puts in front of the user.
public enum UpdateOffer<Release> {
    /// Install this release as usual.
    case install(Release)
    /// Show this release marked "Renew to install", offering Renewal instead of installing it.
    case renewToInstall(Release)
}

extension UpdateOffer: Equatable where Release: Equatable {}
extension UpdateOffer: Sendable where Release: Sendable {}

/// A Licence key that has verified, and the Licence it proves.
///
/// A key is `payload.signature`, both base64url without padding. The payload is UTF-8 JSON, the
/// signature Ed25519 over the payload's bytes. Format 1's payload:
///
///     {"format":1,"id":"lic_…","email":"ada@example.com","windowEnd":"2027-10-01","issued":"2026-10-01"}
///
/// Dates are UTC days. `windowEnd` is the last day whose releases the key covers; lifetime windows
/// use `9999-12-31`. Later formats must keep accepting format 1 keys (ADR 0001).
public struct LicenceKey: Equatable, Sendable {
    public let format: Int
    /// The Licence ID, which Renewals and revocations refer to.
    public let id: String
    public let email: String
    /// Midnight UTC at the start of the update window's last day.
    public let updateWindowEnd: Date
    /// Midnight UTC at the start of the day the key was issued.
    public let issued: Date

    /// Nil unless `text` is a well-formed key in a known format, signed by `publicKey` (raw 32 bytes).
    public init?(verifying text: String, publicKey: Data) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: parts[0]), let signature = Data(base64URL: parts[1]),
              let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              signer.isValidSignature(signature, for: payload),
              let fields = try? JSONDecoder().decode(Format1.self, from: payload), fields.format == 1, !fields.id.isEmpty,
              let windowEnd = Date(utcDay: fields.windowEnd), let issued = Date(utcDay: fields.issued)
        else { return nil }
        format = fields.format
        id = fields.id
        email = fields.email
        updateWindowEnd = windowEnd
        self.issued = issued
    }

    /// Whether the update window covers a release made at `date`, judged by its UTC day.
    func covers(_ date: Date) -> Bool {
        utcCalendar.startOfDay(for: date) <= updateWindowEnd
    }

    private struct Format1: Decodable {
        let format: Int
        let id: String
        let email: String
        let windowEnd: String
        let issued: String
    }
}

/// Everything a build knows about licensing: the public key keys are signed with, its own release
/// date and the Licences revoked when it was released.
public struct LicenceCheck: Sendable {
    public static let trialDays = 14

    let publicKey: Data
    let releaseDate: Date
    let revokedLicences: Set<String>

    /// `releaseDate` is judged by its UTC day; `revokedLicences` holds Licence IDs.
    public init(publicKey: Data, releaseDate: Date, revokedLicences: Set<String>) {
        self.publicKey = publicKey
        self.releaseDate = releaseDate
        self.revokedLicences = revokedLicences
    }

    /// The install's state `now`. A key this build accepts wins over the Trial; a key it refuses
    /// only shows once the Trial is over. A nil `trialStart` means there's no Trial to fall back on.
    public func entitlement(key: String?, trialStart: Date?, now: Date) -> Entitlement {
        let verified = key.flatMap { LicenceKey(verifying: $0, publicKey: publicKey) }
        let revoked = verified.map { revokedLicences.contains($0.id) } ?? false
        if let verified, !revoked, verified.covers(releaseDate) { return .licensed(verified) }
        if let daysLeft = trialDaysLeft(trialStart, now: now) { return .trial(daysLeft: daysLeft) }
        if let verified { return revoked ? .revoked : .updateWindowEnded(verified) }
        return key == nil ? .trialOver : .keyInvalid
    }

    /// Whether this install may take a release published at `releaseDated`: any release during the
    /// Trial, otherwise one whose UTC day is on or before the key's update window end. A release
    /// with no date counts as released at the end of time, so only a lifetime window covers it.
    public func mayTake(releaseDated: Date?, key: String?, trialStart: Date?, now: Date) -> Bool {
        if trialDaysLeft(trialStart, now: now) != nil { return true }
        guard let licence = key.flatMap({ LicenceKey(verifying: $0, publicKey: publicKey) }),
              !revokedLicences.contains(licence.id) else { return false }
        return licence.covers(releaseDated ?? .distantFuture)
    }

    /// What the updater offers from `newer`, the releases newer than this build, newest first.
    /// The newest one this install may take installs. When it may take none, the newest is shown
    /// marked "Renew to install". Nil when there's nothing newer. Every Channel gets the same answer.
    public func offer<Release>(_ newer: [Release], published: (Release) -> Date?, key: String?, trialStart: Date?,
                               now: Date) -> UpdateOffer<Release>? {
        guard let newest = newer.first else { return nil }
        if let takeable = newer.first(where: { mayTake(releaseDated: published($0), key: key, trialStart: trialStart, now: now) }) {
            return .install(takeable)
        }
        return .renewToInstall(newest)
    }

    /// Whole days left counted from the start, or nil once the Trial is over. A clock set before
    /// the start gives the whole Trial.
    private func trialDaysLeft(_ start: Date?, now: Date) -> Int? {
        guard let start else { return nil }
        let daysUsed = Int(max(0, now.timeIntervalSince(start)) / 86_400)
        return daysUsed < Self.trialDays ? Self.trialDays - daysUsed : nil
    }
}

extension Date {
    /// Midnight UTC at the start of a `yyyy-MM-dd` day, the form Licence keys and the bundle's
    /// `SpacetileReleaseDate` use. Nil for anything else, including days that don't exist.
    public init?(utcDay text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        // The calendar rolls 2026-02-30 over to March rather than refusing it
        let parsed = utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard parsed.year == year, parsed.month == month, parsed.day == day else { return nil }
        self = date
    }
}

private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}()

private extension Data {
    /// Base64url, padded or not.
    init?(base64URL text: Substring) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
