import Sparkle
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
final class Updates: NSObject, SPUUpdaterDelegate {
    // Lazy, as it needs self as its delegate, which Sparkle holds weakly.
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

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
}

/// Settings → General: the Channel, the running version, so bug reports can name both, and a check on
/// demand.
struct UpdatesSection: View {
    let check: () -> Void
    @AppStorage(Channel.key) private var channel = Channel.stable
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
    }
}
