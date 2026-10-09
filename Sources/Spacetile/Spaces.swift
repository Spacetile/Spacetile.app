import AppKit
import SpacetileCore
import CSkyLight

/// Native Spaces through SkyLight: reading, switching and moving windows. Each display has its
/// own Desktops, numbered as Mission Control shows them; `Desktops` holds the rules.
enum Spaces {
    typealias ID = Int

    private static let connection = SLSMainConnectionID()

    /// Every display's Desktops, read fresh each time, since Spaces and displays change underneath.
    static var desktops: Desktops {
        let entries = SLSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        // One set of Spaces called "Main" means they span every display ("Displays have separate
        // Spaces" off). Decided by what's in effect, not the preference, which waits for a logout
        if entries.count == 1, entries[0]["Display Identifier"] as? String == "Main" {
            let (spaces, current, order, fullScreen) = desktopList(entries[0])
            let screens = NSScreen.screens.map { screen in
                let id = uuid(of: displayID(screen)) ?? screen.localizedName
                return (id: id, identity: identity(of: screen), frame: CGDisplayBounds(displayID(screen)), index: index(of: id))
            }
            return remember(.spanning(screens: screens, spaces: spaces, current: current, order: order, fullScreen: fullScreen))
        }
        let displays = entries.compactMap { entry -> DisplaySpaces? in
            guard let id = entry["Display Identifier"] as? String, let screen = screen(id: id) else { return nil }
            let (spaces, current, order, fullScreen) = desktopList(entry)
            return DisplaySpaces(id: id, identity: identity(of: screen), frame: CGDisplayBounds(displayID(screen)),
                                 spaces: spaces, current: current, order: order, fullScreen: fullScreen)
        }
        return remember(Desktops(displays: displays, activeID: SLSCopyActiveMenuBarDisplayIdentifier(connection)?.takeRetainedValue() as String?))
    }

    /// A Space set's Desktops (type 0; full-screen app Spaces aren't Desktops), the one showing,
    /// every Space in Mission Control order, full-screen ones included, which switching steps through,
    /// and how the full-screen ones are tiled.
    private static func desktopList(_ entry: [String: Any]) -> (spaces: [ID], current: ID, order: [ID], fullScreen: [ID: FullScreenTiles]) {
        let all = entry["Spaces"] as? [[String: Any]] ?? []
        let spaces = all.filter { $0["type"] as? Int == 0 }.compactMap { $0["ManagedSpaceID"] as? ID }
        let order = all.compactMap { $0["ManagedSpaceID"] as? ID }
        let fullScreen = Dictionary(all.compactMap { space -> (ID, FullScreenTiles)? in
            guard space["type"] as? Int != 0, let id = space["ManagedSpaceID"] as? ID, let tiles = FullScreenTiles(entry: space) else { return nil }
            return (id, tiles)
        }, uniquingKeysWith: { a, _ in a })
        return (spaces, (entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? ID ?? spaces.first ?? 0, order, fullScreen)
    }

    private static func identity(of screen: NSScreen) -> DisplayIdentity {
        let display = displayID(screen)
        return DisplayIdentity(name: screen.localizedName, vendor: CGDisplayVendorNumber(display), model: CGDisplayModelNumber(display),
                               serial: CGDisplaySerialNumber(display), builtIn: CGDisplayIsBuiltin(display) != 0)
    }

    /// The last Desktops read, for mapping windows to Spaces without reading them again per window.
    private static var latest: Desktops?

    private static func remember(_ desktops: Desktops) -> Desktops {
        latest = desktops
        return desktops
    }

    /// A small number per display that stays the same while displays come and go, so a display
    /// keeps its spanning Space IDs, and with them its layouts.
    private static var displayIndexes: [String: Int] = [:]

    private static func index(of display: String) -> Int {
        if let index = displayIndexes[display] { return index }
        displayIndexes[display] = displayIndexes.count
        return displayIndexes.count - 1
    }

    /// The most Desktops any display has. Settings label and lay out Desktops by number, which applies
    /// on every display.
    static var mostDesktops: Int { max(desktops.displays.map(\.spaces.count).max() ?? 1, 1) }

    /// The Space showing on the active display, the one with the menu bar.
    static var active: ID { desktops.activeSpace ?? 0 }

    /// A Space's Desktop number on its own display, or nil for a full-screen app Space.
    static func number(of space: ID) -> Int? { desktops.number(of: space) }

    /// The screen showing `space`, for its visible frame (below the menu bar, beside the Dock).
    static func screen(of space: ID) -> NSScreen? {
        desktops.display(of: space).flatMap { screen(id: $0.id) } ?? NSScreen.main
    }

    static func screen(id: String) -> NSScreen? {
        id == "Main" ? NSScreen.main : NSScreen.screens.first { uuid(of: displayID($0)) == id }
    }

    /// The connected screen with this UUID or display signature (a profile's displays carry those).
    static func screen(matching key: String) -> NSScreen? {
        screen(id: key) ?? NSScreen.screens.first { identity(of: $0).signature == key }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    private static func uuid(of display: CGDirectDisplayID) -> String? {
        CGDisplayCreateUUIDFromDisplayID(display).flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }
    }

    /// Moves a window to another Space with the bridged SkyLight operation (works with SIP on; Phase 0).
    /// Asynchronous: the window server applies it within ~15ms.
    static func move(_ window: WindowID, to space: ID) {
        // Between displays within one shared Space there's nothing for the window server to do: the
        // layout pass puts the window on its new display
        let target = latest?.real(space) ?? space
        if target != space, realSpace(of: window) == target { return }
        guard WSMoveBridged(window, UInt64(target)) else { return log.error("bridged move unavailable") }
    }

    /// The Space a window lives on, or nil for windows on every Space or none.
    /// When Spaces span displays, this is the window's part of its Space: on the display holding
    /// most of it, using `bounds` when the caller has them. A Space that isn't a Desktop (a full-screen
    /// app's) comes back as the window server's own ID, which has no Desktop number.
    static func space(of window: WindowID, bounds: CGRect? = nil) -> ID? {
        guard let real = realSpace(of: window) else { return nil }
        guard let desktops = latest ?? Optional(Self.desktops), desktops.spansDisplays else { return real }
        guard let frame = bounds ?? windowBounds(window),
              let display = desktops.displays.max(by: { overlap($0.frame, frame) < overlap($1.frame, frame) }),
              let index = SpanningSpace.decode(display.current)?.display else { return real }
        let id = SpanningSpace.id(space: real, display: index)
        return display.spaces.contains(id) ? id : real
    }

    /// The Space the window server has the window on, or nil for windows on every Space or none.
    private static func realSpace(of window: WindowID) -> ID? {
        let spaces = SLSCopySpacesForWindows(connection, 0x7, [window] as CFArray)?.takeRetainedValue() as? [ID] ?? []
        return spaces.count == 1 ? spaces[0] : nil
    }

    private static func windowBounds(_ window: WindowID) -> CGRect? {
        // The array holds raw window numbers, not objects
        let ids = [UnsafeRawPointer(bitPattern: UInt(window))]
        let array = ids.withUnsafeBufferPointer { CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), 1, nil) }
        let info = array.flatMap { CGWindowListCreateDescriptionFromArray($0) } as? [[String: Any]]
        return (info?.first?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }
}

// MARK: - Switching

extension Spaces {
    /// Switches to Space `number` with a synthetic dock swipe (instant, no animation). If the
    /// switch hasn't landed shortly after, steps there with the Ctrl+←/→ symbolic hotkeys instead.
    /// Bumped by every switch so a bounce check from an earlier one stands down.
    private static var switchGeneration = 0

    /// Switches the active display to its Desktop `number`, as a profile's `show` names it.
    static func switchTo(space number: Int, then done: @escaping @MainActor () -> Void = {}) {
        let desktops = desktops
        guard let display = desktops.active, let target = desktops.space(number: number, on: display) else { return }
        switchTo(target, then: done)
    }

    /// Switches the active display to the Space at `position`, full-screen ones counted, as ⌥1…⌥0 do.
    static func switchTo(position: Int) {
        let desktops = desktops
        guard let display = desktops.active, let target = desktops.space(position: position, on: display) else { return }
        switchTo(target)
    }

    /// Shows `target` on its display, a Desktop or a full-screen app's Space. Swipes and the ⌃-arrow
    /// fallback step through every Space in Mission Control order, full-screen ones included, so
    /// steps are counted in that order. Both act on the display under the pointer, which isn't
    /// always the active one, so the pointer moves onto the target display first when it's elsewhere.
    static func switchTo(_ target: ID, then done: @escaping @MainActor () -> Void = {}) {
        switchGeneration += 1
        let generation = switchGeneration
        let guarded = !undoingBounce
        undoingBounce = false
        let desktops = desktops
        guard let display = desktops.display(of: target), let signed = display.steps(to: target) else { return }
        let steps = abs(signed), right = signed > 0
        // Spaces spanning displays switch together, so the pointer can stay where it is
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let otherDisplay = !desktops.spansDisplays && desktops.display(containing: pointer)?.id != display.id
        log.notice("switch \(display.name, privacy: .public) \(describe(display.current, on: display), privacy: .public) → \(describe(target, on: display), privacy: .public): \(steps) step(s) \(right ? "right" : "left", privacy: .public)\(otherDisplay ? ", moving the pointer there first" : "", privacy: .public)")
        if otherDisplay { CGWarpMouseCursorPosition(CGPoint(x: display.frame.midX, y: display.frame.midY)) }
        guard steps > 0 else { return done() }
        let interval = signposter.beginInterval("Switch Space")
        let done = {
            signposter.endInterval("Switch Space", interval)
            done()
        }
        for _ in 0..<steps { Swipe.post(right: right, velocity: 2000 * Double(steps)) }
        waitFor(target, timeout: 0.3) { arrived in
            // A newer switch took over: stepping on from here would add to its steps
            guard generation == switchGeneration else { return done() }
            guard !arrived, let remaining = Spaces.desktops.display(of: target)?.steps(to: target) else {
                if guarded { guardAgainstBounce(target: target) }
                return done()
            }
            log.notice("swipe switch bounced, stepping with hotkeys")
            for _ in 0..<abs(remaining) { postSymbolicHotKey(remaining > 0 ? 81 : 79) }
            waitFor(target, timeout: 1) { _ in done() }
        }
    }

    /// "desktop 2" or "full screen", for the log.
    private static func describe(_ space: ID, on display: DisplaySpaces) -> String {
        display.spaces.firstIndex(of: space).map { "desktop \($0 + 1)" } ?? "full screen"
    }

    /// Whether `space` is the one its display is showing.
    static func isShowing(_ space: ID) -> Bool { desktops.display(of: space)?.current == space }

    /// Calls `then` as soon as `target` is showing, or after `timeout` if it isn't by then, saying
    /// which. Fast switches finish without waiting out the timeout.
    private static func waitFor(_ target: ID, timeout: TimeInterval, then: @escaping @MainActor (Bool) -> Void) {
        guard !isShowing(target) else { return then(true) }
        _ = SpaceWait(until: { isShowing(target) }, timeout: timeout, then: then)
    }

    /// Stands down the bounce check of the switch just made: what comes next leaves its Space on
    /// purpose, as a window going full screen does.
    static func expectLeaving() { switchGeneration += 1 }

    /// Whether a bounce is being undone, so the switch back doesn't guard against bouncing again.
    private static var undoingBounce = false

    /// Arriving on a Desktop with none of the front app's windows, macOS activates the next app in
    /// window order, and "switch to a Space with open windows for the application" then follows that
    /// app to its own Space. A second switch sticks, since that app is already active, so switch back
    /// once, unless a key or click since the switch (⌘Tab, the Dock) asked for the move. A newer
    /// switch stands the guard down.
    private static func guardAgainstBounce(target: ID) {
        let generation = switchGeneration, start = Date()
        _ = SpaceWait(until: { !isShowing(target) }, timeout: 1) { left in
            guard left, generation == switchGeneration, !userActed(since: start) else { return }
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            log.notice("bounced: left desktop \(number(of: target) ?? 0) for desktop \(number(of: active) ?? 0) with \(front, privacy: .public) in front, switching back")
            undoingBounce = true
            switchTo(target)
        }
    }

    private static func userActed(since start: Date) -> Bool {
        let elapsed = Date().timeIntervalSince(start)
        return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < elapsed
        }
    }

    /// Posts the key combo bound to a symbolic hotkey (79/81: move left/right a Space).
    private static func postSymbolicHotKey(_ hotKey: CGSSymbolicHotKey) {
        var key: CGKeyCode = 0, modifiers: UInt32 = 0
        guard CGSGetSymbolicHotKeyValue(hotKey, nil, &key, &modifiers) == .success,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
        down.flags = CGEventFlags(rawValue: UInt64(modifiers))
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Synthetic trackpad dock swipe. macOS 27 ignores these unless an IOHID payload is appended to
/// the serialized event. Field numbers and payload layout from WhichSpace (MIT).
private enum Swipe {
    private enum Field {
        static let eventType = CGEventField(rawValue: 55)!
        static let hidType = CGEventField(rawValue: 110)!
        static let motion = CGEventField(rawValue: 123)!
        static let progress = CGEventField(rawValue: 124)!
        static let positionX = CGEventField(rawValue: 125)!
        static let velocityX = CGEventField(rawValue: 129)!
        static let velocityY = CGEventField(rawValue: 130)!
        static let phase = CGEventField(rawValue: 132)!
        static let phase2 = CGEventField(rawValue: 134)!
        static let flavor = CGEventField(rawValue: 138)!
        static let timestamp = CGEventField(rawValue: 169)!
        static let iohidPayload: UInt16 = 4205
    }

    /// One Space per swipe: began, changed, ended.
    static func post(right: Bool, velocity: Double) {
        // Dock applies the natural-scrolling inversion to HID-backed swipes
        let natural = (CFPreferencesCopyValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int ?? 1) != 0
        let goRight = natural ? right : !right
        for phase: Int64 in [1, 2, 4] { postPhase(phase, right: goRight, velocity: velocity) }
    }

    private static func postPhase(_ phase: Int64, right: Bool, velocity: Double) {
        guard let event = CGEvent(source: nil) else { return }
        let progress = right ? 1.0 : -1.0
        let signed = right ? velocity : -velocity
        event.setIntegerValueField(Field.eventType, value: 30) // dock control
        event.setIntegerValueField(Field.hidType, value: 23) // dock swipe
        event.setIntegerValueField(Field.phase, value: phase)
        event.setDoubleValueField(Field.progress, value: progress)
        event.setIntegerValueField(Field.motion, value: 1) // horizontal
        event.setDoubleValueField(Field.velocityX, value: signed)
        event.setDoubleValueField(Field.velocityY, value: 0)
        event.setIntegerValueField(Field.phase2, value: phase)
        event.setDoubleValueField(Field.flavor, value: 3) // dock primary
        event.setDoubleValueField(Field.timestamp, value: Double(mach_absolute_time()))
        event.setDoubleValueField(Field.positionX, value: 0.1)
        guard var bytes = event.data as Data?, bytes.starts(with: [0, 0, 0, 2]) else { return }

        var payload = Data()
        // IOHIDSystemQueueElementHeader: timestamp, senderID, options, attributeLength, eventCount
        append(event.timestamp != 0 ? event.timestamp : mach_absolute_time(), to: &payload)
        append(UInt64(0), to: &payload); append(UInt32(0), to: &payload)
        append(UInt32(0), to: &payload); append(UInt32(2), to: &payload)
        // Fluid touch gesture (IOHID event type 23)
        append(UInt32(40), to: &payload); append(UInt32(23), to: &payload)
        append(UInt32((phase & 0xFF) << 24), to: &payload); append(UInt32(0), to: &payload)
        append(fixed(0.1), to: &payload); append(fixed(0), to: &payload); append(Int32(0), to: &payload)
        append(UInt32(0), to: &payload); append(UInt16(1), to: &payload); append(UInt16(3), to: &payload)
        append(fixed(-progress), to: &payload)
        // Velocity (IOHID event type 9)
        append(UInt32(28), to: &payload); append(UInt32(9), to: &payload)
        append(UInt32(0), to: &payload); append(UInt32(1), to: &payload)
        append(fixed(-signed), to: &payload); append(Int32(0), to: &payload); append(Int32(0), to: &payload)

        bytes.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF),
                                  UInt8(Field.iohidPayload >> 8), UInt8(Field.iohidPayload & 0xFF)])
        bytes.append(payload)
        CGEvent(withDataAllocator: kCFAllocatorDefault, data: bytes as CFData)?.post(tap: .cgSessionEventTap)
    }

    private static func append<T>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    /// 16.16 fixed point, keeping tiny non-zero values non-zero.
    private static func fixed(_ value: Double) -> Int32 {
        let scaled = value * 65_536
        if scaled >= Double(Int32.max) { return .max }
        if scaled <= Double(Int32.min) { return .min }
        let result = Int32(scaled)
        return result == 0 && value != 0 ? (value > 0 ? 1 : -1) : result
    }
}

/// Waits for a Space change that makes `until` true, or `timeout`, whichever comes first, then says
/// whether it held. Keeps itself alive through its observer and timer until it finishes.
private final class SpaceWait {
    private var observer: NSObjectProtocol?
    private let then: @MainActor (Bool) -> Void

    init(until: @escaping @MainActor () -> Bool, timeout: TimeInterval, then: @escaping @MainActor (Bool) -> Void) {
        self.then = then
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [self] _ in
            MainActor.assumeIsolated { if until() { finish(true) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in finish(until()) }
    }

    private func finish(_ arrived: Bool) {
        guard let observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        self.observer = nil
        then(arrived)
    }
}
