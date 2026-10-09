import AppIntents
import Foundation

/// A Focus filter (System Settings → Focus → a Focus → Add Filter → Spacetile): loads one profile
/// when the Focus turns on and, optionally, another when it turns off.
///
/// macOS calls `perform` on both events; when the Focus turns off the parameters arrive empty, so
/// the "ends" profile is remembered from the activation.
struct SpacetileFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Load Spacetile Profile"
    static let description = IntentDescription("Rearranges your Spaces with a Spacetile profile while this Focus is on.")

    @Parameter(title: "Profile", optionsProvider: ProfileOptions())
    var profile: String?

    @Parameter(title: "When Focus ends, load", optionsProvider: ProfileOptions())
    var endProfile: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(profile ?? "No profile")", subtitle: endProfile.map { "Then \($0) when it ends" })
    }

    private static let endKey = "focusFilterEndProfile"

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults.standard
        if let profile {
            defaults.set(endProfile, forKey: Self.endKey)
            await FocusFilterRouter.load(profile)
        } else if let end = defaults.string(forKey: Self.endKey) {
            defaults.removeObject(forKey: Self.endKey)
            await FocusFilterRouter.load(end)
        }
        return .result()
    }
}

struct ProfileOptions: DynamicOptionsProvider {
    func results() async throws -> [String] { ProfileStore.all.map(\.name) }
}

/// Connects the intent, which macOS runs inside the app, to the running window manager.
enum FocusFilterRouter {
    static var handler: (String) -> Void = { _ in }

    static func load(_ profile: String) {
        log.notice("focus filter loading \(profile, privacy: .public)")
        handler(profile)
    }
}
