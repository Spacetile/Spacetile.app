import AppKit
import Sparkle
import SpacetileCore
import SwiftUI

/// The stream of releases this install follows. Kept in UserDefaults, as it belongs to the install
/// rather than to config.json.
enum Channel: String, CaseIterable, Identifiable {
    case stable, beta, nightly

    static let key = "updateChannel"
    static var current: Channel { UserDefaults.standard.string(forKey: key).flatMap(Channel.init) ?? .stable }

    var id: Self { self }
    var title: String { rawValue.capitalized }

    /// The appcast's sparkle:channel tags this Channel accepts. Stable items carry no tag, so every
    /// Channel sees them too.
    var appcastChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: ["beta"]
        case .nightly: ["beta", "nightly"]
        }
    }
}

/// Sparkle 2, checking the appcast in Info.plist's SUFeedURL (set by scripts/bundle.sh) for the
/// Channel picked in Settings. The rest of the app only sees `check`, so Sparkle stays in this file.
///
/// Each release is judged by the Licence (`Licence.offer`, `Licence.mayTake`) on its coverage
/// (`coverage(of:)`), the same way on every Channel. One the install may not take never reaches
/// Sparkle's install window: the check ends quietly and Spacetile shows it marked "Renew to
/// install", with a Renew button in place of Install.
final class Updates: NSObject, SPUUpdaterDelegate {
    private static let renewShownKey = "renewToInstallShown"

    private let licence: Licence
    // Lazy, as it needs self as its delegate, which Sparkle holds weakly.
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    /// The release the current check found but this install may not take, shown when the check ends.
    private var renewToInstall: SUAppcastItem?

    init(licence: Licence) {
        self.licence = licence
        super.init()
    }

    /// Starts the scheduled checks. A bare `swift run` binary has no Info.plist and so no feed; Sparkle
    /// would alert that it can't start, so it stays off there.
    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller.startUpdater()
    }

    /// Checks now and shows the result, or brings forward an update already in progress.
    func check() {
        guard controller.updater.sessionInProgress || controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    /// Read on every check, so a new Channel applies from the next one.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { Channel.current.appcastChannels }

    /// The coverage the release pipeline wrote into the item's spacetileCoverage element, the same
    /// value as in that build's Info.plist. Items from before it have none and count from their
    /// publish date. Sparkle keeps elements it doesn't know in `propertiesDictionary`, keyed by name.
    static func coverage(of item: SUAppcastItem) -> Coverage? {
        (item.propertiesDictionary["spacetileCoverage"] as? String).flatMap { Coverage(text: $0) }
            ?? item.date.map { .windowOpenOn($0) }
    }

    /// The newest release the Licence covers, so an older release it covers still installs when a
    /// newer one needs a Renewal. When it covers none, the newest, which
    /// `shouldProceedWithUpdate` then turns into "Renew to install". Sparkle has already dropped
    /// the items for other Channels and other macOS versions.
    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let versions = SUStandardVersionComparator.default
        let running = updater.hostBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let newer = appcast.items
            .filter { versions.compareVersion(running, toVersion: $0.versionString) == .orderedAscending }
            .sorted { versions.compareVersion($0.versionString, toVersion: $1.versionString) == .orderedDescending }
        switch licence.offer(newer, coverage: Self.coverage(of:)) {
        case .install(let item)?, .renewToInstall(let item)?: return item
        // Nothing newer: Sparkle reports that it's up to date
        case nil: return nil
        }
    }

    /// Stops a release the Licence doesn't cover before Sparkle offers to install it. Sparkle ends
    /// the check without an alert of its own for SUInstallationCanceledError
    /// (SPUUIBasedUpdateDriver.m, `_abortUpdateWithError:showErrorToUser:`); the release is shown
    /// when the check ends.
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard !licence.mayTake(Self.coverage(of: updateItem)) else { return }
        renewToInstall = updateItem
        throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue), userInfo: [
            NSLocalizedDescriptionKey: "Spacetile \(updateItem.displayVersionString) needs a Renewal to install.",
        ])
    }

    /// Shows the release `shouldProceedWithUpdate` held back: every time for a check the user asked
    /// for, once per release for scheduled checks, so a background check doesn't nag daily.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard let item = renewToInstall else { return }
        renewToInstall = nil
        let defaults = UserDefaults.standard
        switch updateCheck {
        case .updates: break
        case .updatesInBackground:
            guard defaults.string(forKey: Self.renewShownKey) != item.versionString else { return }
        case .updateInformation: return
        @unknown default: return
        }
        defaults.set(item.versionString, forKey: Self.renewShownKey)
        showRenewToInstall(item)
    }

    /// "Renew to install": Renew opens the Renewal checkout. Without a Licence to renew (the Trial
    /// over, or a revoked key) it offers to buy one instead.
    private func showRenewToInstall(_ item: SUAppcastItem) {
        // A lifetime Licence takes every release, so it never gets here
        guard let checkout = licence.checkout else { return }
        let alert = NSAlert()
        alert.messageText = "Spacetile \(item.displayVersionString) is available: Renew to install"
        switch checkout {
        case .renew:
            let windowEnd = licence.state.licence.map { " ended on \(Licence.day($0.updateWindowEnd))" } ?? " has ended"
            alert.informativeText = "Your Licence's update window\(windowEnd). \(Licence.needs(Self.coverage(of: item))) Renew your Licence to install it. The version you have keeps working."
            alert.addButton(withTitle: "Renew Licence…")
        case .buy:
            alert.informativeText = "This release needs a Licence to install."
            alert.addButton(withTitle: "Buy a Licence…")
        }
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        licence.openCheckout()
    }
}

/// Settings → General: the Channel, the running version, so bug reports can name both, a check on
/// demand, and the licence notices bundle.sh collects (absent from unbundled builds).
struct UpdatesSection: View {
    let check: () -> Void
    @AppStorage(Channel.key) private var channel = Channel.stable
    @State private var showingAcknowledgements = false
    // Shown in a sheet rather than opened in TextEdit, which could save edits into the signed bundle
    private let acknowledgements = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private let version = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String else {
            return "Unbundled build"
        }
        return "\(short) (\(build))"
    }()

    var body: some View {
        Picker("Channel", selection: $channel) {
            ForEach(Channel.allCases) { Text($0.title).tag($0) }
        }
        LabeledContent("Version", value: version)
        Button("Check for Updates…", action: check)
        if let acknowledgements {
            Button("Acknowledgements…") { showingAcknowledgements = true }
                .sheet(isPresented: $showingAcknowledgements) {
                    VStack(alignment: .trailing) {
                        ScrollView {
                            Text(acknowledgements)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Done") { showingAcknowledgements = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding()
                    .frame(width: 600, height: 480)
                }
        }
    }
}
