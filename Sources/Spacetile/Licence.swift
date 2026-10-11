import AppKit
import Foundation
import Observation
import SpacetileCore

/// The install's Trial and Licence key, kept in the Keychain, and what they entitle it to. Tiling
/// and profiles stop while `licenceNeeded`; the menu bar and Settings keep working.
@Observable final class Licence {
    /// The raw Ed25519 public key that Licence keys are signed with, base64: the public half of the
    /// licence service's signing key (SST_SECRET_LicenceSigningKey).
    static let publicKey = "1IGpIV3w9B+ehJ8/a1RUwq5CfbF5DYl3myKfLtZYwq0="

    /// The site's Buy page, which the Buy buttons open through `openCheckout()`. It offers both ways
    /// to buy, a Licence and Lifetime supporter, each through its own Payment Link, so the app needs
    /// neither link. Shipped builds open this address, so the site must keep serving it.
    static let buyPage = URL(string: "https://spacetile.app/buy/")!

    /// The Renewal Payment Link, which the Renew buttons open through `openCheckout()`.
    /// Placeholder until production has the Renewal Payment Link: the site's production deploy
    /// creates it in Stripe and outputs it as `renewalPaymentLink`; replace this with that URL.
    /// Release builds fail while the app binary holds the marker SPACETILE-PLACEHOLDER.
    static let renewalLink = URL(string: "https://buy.stripe.com/SPACETILE-PLACEHOLDER-renewal-payment-link")!

    #if SPACETILE_DEV
    /// `bundle.sh --dev` compiles the gate out, so contributors can run Spacetile without a Licence.
    static let gated = false
    /// Why tiling and profiles run without a Licence, for Settings; nil when the build has the gate.
    static let whyUngated: String? = "Development build: tiling and profiles work without a Licence."
    #else
    /// Every build but `--dev` has the gate, local default builds included, except releases
    /// numbered below 1.0.0 (`LicenceGate`): the free public beta, whose users' Trial starts on 1.0.
    static let gated: Bool = {
        let info = Bundle.main.infoDictionary ?? [:]
        return LicenceGate.applies(toVersion: info["CFBundleShortVersionString"] as? String,
                                   released: info["SpacetileReleaseDate"] != nil)
    }()
    /// Why tiling and profiles run without a Licence, for Settings; nil when the build has the gate.
    static let whyUngated: String? = gated ? nil
        : "Spacetile is free until 1.0: tiling and profiles work without a Licence, and the Trial starts when you first run 1.0."
    #endif

    private static let keyAccount = "licence-key"

    private(set) var state: Entitlement
    private let check: LicenceCheck
    private let trialStart: Date?
    private var key: String?
    /// Called whenever `state` changes.
    @ObservationIgnored var onChange: (Entitlement) -> Void = { _ in }

    /// Neither in the Trial nor Licensed, in a build with the gate: tiling and profiles stop.
    var licenceNeeded: Bool { Self.gated && !state.isEntitled }

    /// Why tiling and profiles stopped, in a few words for the menu bar; nil while they run.
    var whyStopped: String? {
        guard licenceNeeded else { return nil }
        switch state {
        case .trialOver: return "Trial over"
        case .keyInvalid: return "Licence key not valid"
        case .revoked: return "Licence revoked"
        case .updateWindowEnded: return "update window ended before this version"
        case .trial, .licensed: return nil
        }
    }

    /// Reads the key and Trial start from the Keychain. The first launch of a gated build starts
    /// the Trial; deleting the Keychain item starts it again (soft enforcement).
    init(now: Date = .now) {
        let info = Bundle.main.infoDictionary ?? [:]
        // Release builds record their UTC day (bundle.sh --release). Other builds have none and
        // count as released today, so a key covers them while its update window is open.
        let released = (info["SpacetileReleaseDate"] as? String).flatMap { Date(utcDay: $0) } ?? now
        // Release builds carry the Licences revoked when they were made (bundle.sh --revocations).
        // Other builds have no list and refuse no Licence.
        let revoked = Bundle.main.url(forResource: "Revocations", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { Revocations.licenceIDs(in: $0) } ?? []
        let check = LicenceCheck(publicKey: Data(base64Encoded: Self.publicKey) ?? Data(), releaseDate: released, revokedLicences: revoked)
        let trialStart = Self.readTrialStart(now: now)
        let key = Keychain.read(Self.keyAccount)
        self.check = check
        self.trialStart = trialStart
        self.key = key
        state = check.entitlement(key: key, trialStart: trialStart, now: now)
    }

    #if SPACETILE_DEV
    /// Development builds have no Trial.
    private static func readTrialStart(now _: Date) -> Date? { nil }
    #else
    private static let trialAccount = "trial-start"

    /// The Trial's start, from the Keychain. A gated build without one starts the Trial `now`; an
    /// ungated build writes none, so the Trial starts on the first gated build the install runs.
    private static func readTrialStart(now: Date) -> Date? {
        if let stored = Keychain.read(trialAccount).flatMap({ Double($0) }) { return Date(timeIntervalSince1970: stored) }
        guard gated else { return nil }
        Keychain.write(String(now.timeIntervalSince1970), to: trialAccount)
        return now
    }
    #endif

    /// Judges the stored key and Trial again, for the Trial running out while Spacetile is open.
    func refresh(now: Date = .now) {
        let new = check.entitlement(key: key, trialStart: trialStart, now: now)
        guard new != state else { return }
        state = new
        onChange(new)
    }

    /// Stores `text` in the Keychain if this build accepts it. Otherwise returns why not and keeps
    /// the key stored before.
    func enter(_ text: String, now: Date = .now) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Judged without the Trial, so a bad key isn't hidden behind it
        switch check.entitlement(key: text, trialStart: nil, now: now) {
        case .licensed:
            guard Keychain.write(text, to: Self.keyAccount) else { return "Couldn't save the key to the keychain." }
            key = text
            refresh(now: now)
            return nil
        case .revoked:
            return "This Licence has been revoked."
        case .updateWindowEnded(let licence):
            return "This Licence's update window ended on \(Self.day(licence.updateWindowEnd)), before this version was released. Renew it to use this version."
        case .keyInvalid, .trialOver, .trial:
            return "That isn't a valid Licence key. Copy the whole key from your Licence email."
        }
    }

    /// What a Buy or Renew button offers.
    enum Checkout {
        /// A new Licence, through the site's Buy page.
        case buy
        /// A Renewal of the stored Licence.
        case renew
    }

    /// Renew when there's a Licence key whose update window can end, Buy when there's none; nil for
    /// a lifetime Licence, which needs neither. Every Buy and Renew button asks this.
    var checkout: Checkout? {
        guard let licence = state.licence else { return .buy }
        return Self.isLifetime(licence.updateWindowEnd) ? nil : .renew
    }

    /// Opens `checkout` in the browser. The fresh key arrives by email and activates like any other.
    func openCheckout() {
        switch checkout {
        case .buy?: NSWorkspace.shared.open(Self.buyPage)
        case .renew?: if let licence = state.licence { NSWorkspace.shared.open(Self.renewalCheckout(for: licence)) }
        case nil: break
        }
    }

    /// The Renewal checkout for `licence`: the Renewal Payment Link with the Licence ID as
    /// `client_reference_id`, which tells the licence service which Licence to extend.
    static func renewalCheckout(for licence: LicenceKey) -> URL {
        renewalLink.appending(queryItems: [URLQueryItem(name: "client_reference_id", value: licence.id)])
    }

    /// Whether this install may take a release published at `date`, nil when the appcast gives none.
    /// A build without the gate may take any release.
    func mayTake(releaseDated date: Date?, now: Date = .now) -> Bool {
        guard Self.gated else { return true }
        return check.mayTake(releaseDated: date, key: key, trialStart: trialStart, now: now)
    }

    /// What the updater offers from `newer`, the releases newer than this build, newest first. A
    /// build without the gate installs the newest.
    func offer<Release>(_ newer: [Release], published: (Release) -> Date?, now: Date = .now) -> UpdateOffer<Release>? {
        guard Self.gated else { return newer.first.map { .install($0) } }
        return check.offer(newer, published: published, key: key, trialStart: trialStart, now: now)
    }

    /// Whether an update window end is the far-future end that lifetime Licences carry.
    static func isLifetime(_ windowEnd: Date) -> Bool {
        windowEnd >= Date(utcDay: "9000-01-01") ?? .distantFuture
    }

    /// An update window end as the UTC day it names, or "never" for a lifetime window.
    static func day(_ date: Date) -> String {
        guard !isLifetime(date) else { return "never (lifetime)" }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }
}
