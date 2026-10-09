import Carbon
import SpacetileCore

/// Global hotkeys through Carbon's `RegisterEventHotKey`, which needs no permission. ⌥-only
/// combinations register on macOS 27 (checked before Phase 1).
///
/// One long-lived instance: the Carbon handler holds an unretained pointer to it, so bindings are
/// swapped with `rebind` rather than by replacing the object.
final class Hotkeys {
    struct Registration {
        let chord: String
        let command: Command?
        /// Why the binding isn't active, if it isn't.
        let problem: String?
    }

    private(set) var registrations: [Registration] = []
    private var refs: [EventHotKeyRef] = []
    private var commands: [UInt32: Command] = [:]
    private var current = Settings.default
    /// While tiling is paused only `pause` stays registered, so games and other apps get every
    /// other chord back. With shortcuts turned off in Settings, nothing is.
    var paused = false {
        didSet { if paused != oldValue { rebind(current) } }
    }
    private let handler: (Command) -> Void

    init(handler: @escaping (Command) -> Void) {
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func rebind(_ settings: Settings) {
        current = settings
        unregisterAll()
        registrations = settings.bindings.enumerated().map { index, entry in
            switch entry.binding {
            case .failure(.badChord):
                return Registration(chord: entry.chord, command: nil, problem: "Unknown key or modifier")
            case .failure(.badCommand(let text)):
                return Registration(chord: entry.chord, command: nil, problem: "Unknown command “\(text)”")
            case let .success((_, command)) where !settings.usesShortcuts || (paused && command != .togglePause):
                return Registration(chord: entry.chord, command: command, problem: nil)
            case let .success((chord, command)):
                var ref: EventHotKeyRef?
                let id = UInt32(index)
                let status = RegisterEventHotKey(chord.keyCode, chord.carbonModifiers, EventHotKeyID(signature: 0x4253_5043, id: id),
                                                 GetEventDispatcherTarget(), 0, &ref)
                guard status == noErr, let ref else {
                    let problem = status == eventHotKeyExistsErr ? "Already used by another app" : "Couldn't register (\(status))"
                    return Registration(chord: entry.chord, command: command, problem: problem)
                }
                refs.append(ref)
                commands[id] = command
                return Registration(chord: entry.chord, command: command, problem: nil)
            }
        }
    }

    /// Releases every hotkey so a key recorder can see the keystrokes they would consume.
    func suspend() { unregisterAll() }
    func resume() { rebind(current) }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        commands = [:]
    }

    private func fire(_ id: UInt32) {
        commands[id].map(handler)
    }
}
