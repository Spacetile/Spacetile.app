import CoreGraphics
import Foundation
import SpacetileCore

/// The running layouts in `~/Library/Application Support/<bundle ID>/session.json`, for the next
/// launch to put back, so a development build and the release each keep their own. Not a profile:
/// nothing lists or edits it.
enum SessionStore {
    static let file = URL.applicationSupportDirectory
        .appending(path: "\(Bundle.main.bundleIdentifier ?? "com.kodehort.spacetile")/session.json")

    /// When the Mac last started, in seconds since 1970.
    static let boot: Int = {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &time, &size, nil, 0)
        return time.tv_sec
    }()

    /// The window server's process ID, from the menu bar it owns, on screen or not.
    static let windowServer: Int32 = {
        let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return info.first { $0[kCGWindowOwnerName as String] as? String == "Window Server" }?[kCGWindowOwnerPID as String] as? Int32 ?? 0
    }()

    /// The session saved since the user last logged in, if any.
    static func load() -> Session? {
        guard let data = try? Data(contentsOf: file), let session = try? JSONDecoder().decode(Session.self, from: data),
              session.boot == boot, session.windowServer == windowServer else { return nil }
        return session
    }

    static func save(_ session: Session) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: file, options: .atomic)
        } catch {
            log.error("saving the session failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
