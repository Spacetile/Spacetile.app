import Foundation

/// A persistent command shared by interactive shells and automation. No shell startup files are edited.
public struct CommandLineLink: Sendable {
    public static let installedPath = "/usr/local/bin/spacetile"
    public let executable: String
    public let destination: String

    public enum Status: Equatable, Sendable {
        case missing, installed, conflict
    }

    public init(executable: String, destination: String = installedPath) {
        self.executable = executable
        self.destination = destination
    }

    public var status: Status {
        let files = FileManager.default
        if let target = try? files.destinationOfSymbolicLink(atPath: destination) {
            // Relative symlinks are valid too. A broken or unrelated link is a conflict, never overwritten.
            let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: target, relativeTo: parent).standardizedFileURL.path
            return resolved == URL(fileURLWithPath: executable).standardizedFileURL.path ? .installed : .conflict
        }
        return (try? files.attributesOfItem(atPath: destination)) == nil ? .missing : .conflict
    }

    /// Try without elevation first. The caller may retry with macOS authentication on a permission error.
    public func install() throws {
        switch status {
        case .installed: return
        case .conflict: throw CocoaError(.fileWriteFileExists)
        case .missing: break
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // No remove/replace step: a command appearing after the check is also left untouched.
        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: executable)
    }

    /// Uses absolute system tools; neither the user's PATH nor shell configuration is evaluated as code.
    /// `ln` deliberately has no force option. Recheck after the authentication prompt, too.
    public var installShellScript: String {
        let link = Self.shellQuote(destination)
        let target = Self.shellQuote(executable)
        let directory = Self.shellQuote(URL(fileURLWithPath: destination).deletingLastPathComponent().path)
        return """
        set -eu
        if [ -L \(link) ] && [ "$(/usr/bin/readlink \(link))" = \(target) ]; then exit 0; fi
        if [ -e \(link) ] || [ -L \(link) ]; then
            /usr/bin/printf '%s\\n' 'An existing spacetile command was left unchanged.' >&2
            exit 1
        fi
        /bin/mkdir -p \(directory)
        /bin/ln -s -h \(target) \(link)
        """
    }

    public var installAppleScript: String {
        let literal = installShellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(literal)\" with administrator privileges"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
