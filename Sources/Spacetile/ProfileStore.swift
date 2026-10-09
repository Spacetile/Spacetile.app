import AppKit
import SpacetileCore

/// Profiles as pretty-printed JSON files in `~/.config/spacetile/profiles/`, one per profile, so they
/// can be read, edited and kept in dotfiles.
enum ProfileStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/spacetile/profiles", directoryHint: .isDirectory)

    /// A profile file that doesn't load, kept so Settings can say why instead of hiding it.
    struct Problem: Hashable {
        let file: URL
        let message: String
    }

    static var all: [Profile] { load().profiles }

    static func load() -> (profiles: [Profile], problems: [Problem]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var profiles: [Profile] = []
        var problems: [Problem] = []
        for file in files where file.pathExtension == "json" {
            do {
                profiles.append(try JSONDecoder().decode(Profile.self, from: Data(contentsOf: file)))
            } catch {
                problems.append(Problem(file: file, message: ConfigStore.describe(error)))
            }
        }
        return (profiles.sorted { $0.name < $1.name }, problems.sorted { $0.file.lastPathComponent < $1.file.lastPathComponent })
    }

    static func file(of profile: Profile) -> URL {
        directory.appending(path: profileFileName(profile.name))
    }

    static func named(_ name: String) -> Profile? { all.first { $0.name == name } }

    static func save(_ profile: Profile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: file(of: profile), options: .atomic)
    }
}

extension Profile {
    /// The icon to draw: the profile's, or the default when it has none or names no SF Symbol.
    var symbol: String {
        icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? Self.defaultIcon
    }
}
