import Foundation
import SpacetileCore

/// `~/.config/spacetile/config.json`: written with defaults on first launch, reloaded whenever it
/// changes (from an editor or the settings window). A file that doesn't parse leaves the last good
/// settings running and is never overwritten; the error is reported instead.
final class ConfigStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/spacetile", directoryHint: .isDirectory)
    static let file = directory.appending(path: "config.json")

    private(set) var settings = Settings.default
    private(set) var error: String?
    /// Called with every successfully loaded or saved configuration, and on errors.
    var onChange: (ConfigStore) -> Void = { _ in }

    /// The bytes last loaded or written, so our own saves and no-op events don't reload.
    private var lastData: Data?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    /// Replacing it cancels the old source, which closes its descriptor.
    private var fileWatcher: DispatchSourceFileSystemObject? {
        didSet { oldValue?.cancel() }
    }
    private var reload: DispatchWorkItem?

    func start() {
        if !FileManager.default.fileExists(atPath: Self.file.path) { save(.default) }
        load()
        watch()
    }

    func save(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try encoder.encode(settings)
            try data.write(to: Self.file, options: .atomic)
            lastData = data
            self.settings = settings
            error = nil
            onChange(self)
        } catch {
            self.error = "Couldn't save config: \(error.localizedDescription)"
            onChange(self)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file), data != lastData else { return }
        lastData = data
        do {
            settings = try JSONDecoder().decode(Settings.self, from: data)
            error = nil
            log.notice("config loaded")
        } catch {
            self.error = "config.json: \(Self.describe(error).trimmingCharacters(in: .punctuationCharacters)). Still using the last good settings."
            log.error("\(self.error ?? "", privacy: .public)")
        }
        onChange(self)
    }

    /// Watches the directory for editors that save by renaming a new file over the old one, and the
    /// file itself for in-place writes. The file watch is re-attached after every change because a
    /// rename leaves it pointing at the replaced file.
    private func watch() {
        directoryWatcher = Self.watcher(for: Self.directory, events: .write) { [weak self] in self?.scheduleReload() }
        fileWatcher = Self.watcher(for: Self.file, events: [.write, .delete, .rename]) { [weak self] in self?.scheduleReload() }
    }

    private func scheduleReload() {
        // Editors write in several steps; read once they've finished
        reload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.load()
            self?.fileWatcher = Self.watcher(for: Self.file, events: [.write, .delete, .rename]) { self?.scheduleReload() }
        }
        reload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private static func watcher(for url: URL, events: DispatchSource.FileSystemEvent,
                                handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated(handler) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// A decoding error as "path: what's wrong", for messages about hand-edited files.
    nonisolated static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case let .dataCorrupted(context), let .keyNotFound(_, context), let .typeMismatch(_, context), let .valueNotFound(_, context):
            let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
