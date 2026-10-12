import Foundation

/// The End User Licence Agreement at https://spacetile.app/eula/, which the Welcome guide's first
/// page asks people to agree to before tiling starts. The version and date accepted are kept in
/// UserDefaults, as they belong to the install.
public enum EULA {
    /// The agreement's `updated` date in `site/src/content/legal/eula.md`, which
    /// `site/test/eula-version.test.ts` holds it to. Change it with the text: a version this install
    /// hasn't accepted shows the guide again on the next launch.
    public static let version = "2026-10-12"
    public static let url = URL(string: "https://spacetile.app/eula/")!
    static let versionKey = "eulaVersion"
    static let dateKey = "eulaAccepted"

    public static func isAccepted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: versionKey) == version
    }

    public static func accept(in defaults: UserDefaults = .standard, on date: Date = .now) {
        defaults.set(version, forKey: versionKey)
        defaults.set(date, forKey: dateKey)
    }
}
