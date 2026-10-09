import AppKit
import SpacetileCore

/// Tracks every standard window through Accessibility and keeps each Space's layout applied.
/// Everything runs on the main actor: AX observer callbacks, hotkeys and workspace notifications
/// are all main-run-loop sources, so a single writer avoids races.
final class WindowManager {
    /// What the menu-bar item draws.
    struct Status {
        var space: Int?
        var label: String?
        var stacked = 0
        var total = 0
        var mode = LayoutMode.bsp
        /// Windows Spacetile manages on this Space, tiled and floating.
        var windowCount = 0
        /// Of those, the ones floating above the tiles.
        var floating = 0
        var paused = false
        /// Each display's current position, in arrangement order, for the every-display style.
        var displays: [DisplayIndex] = []
        /// Showing a full-screen app's Space: the layout item shows that in place of the mode.
        var isFullScreen = false
        /// The active display's Spaces in Mission Control order, for the stepper.
        var order: [StepSlot] = []
        /// The profile applied, or saved from the mini-map, last, and its icon.
        var profile: String?
        var profileIcon: String?
    }

    struct DisplayIndex {
        let number: Int?
        let isActive: Bool
    }

    enum StepSlot: Equatable {
        /// Whether it has any windows: the stepper outlines these.
        case desktop(occupied: Bool)
        case fullScreen
    }

    /// Which Spaces have windows, refreshed at most twice a second: it asks the window server
    /// about every window, and status publishes on every focus change.
    private var occupancy: (spaces: [Bool], at: Date) = ([], .distantPast)

    private var windows: [WindowID: AXWindow] = [:]
    private var layouts: [Spaces.ID: SpaceLayout] = [:]
    /// The tiled window new windows split beside. Only windows already in a tree are recorded, so a
    /// new window that grabs focus before its creation event arrives can't become its own anchor.
    private var lastFocusedTiled: [Spaces.ID: WindowID] = [:]
    /// The empty display `display next|prev` last moved to. Focus stays on the window it left, so
    /// without this the next step would start from that window's display again.
    private var emptyDisplay: String?
    /// Says why a drop didn't split, over the tile it landed in.
    private let notice = Overlay()
    /// The profile applied, or saved from the mini-map, last, which the menu-bar list marks, the menu-bar item can show
    /// and Save Current Layout… offers to update. Kept across launches.
    private(set) var lastProfile: String? = UserDefaults.standard.string(forKey: WindowManager.lastProfileKey) {
        didSet { UserDefaults.standard.set(lastProfile, forKey: Self.lastProfileKey) }
    }
    private static let lastProfileKey = "lastProfile"
    /// `lastProfile`'s icon, kept here so publishing status doesn't read the profile files.
    private var lastProfileIcon: String?
    /// Layouts of disconnected displays, and the displays last seen, to notice one returning.
    private var departed = DepartedLayouts()
    private var lastDesktops: Desktops?
    /// From a display change or wake until the displays settle.
    private var displaysUnsettled = false
    /// Smallest sizes windows accepted, learned by reading frames back after each write.
    private var minimumSizes: MinimumSizes = [:]
    private var observers: [pid_t: AXObserver] = [:]
    /// Where windows now in native full screen or minimised sat, so coming back puts them there.
    private var savedSlots: [WindowID: (pid: pid_t, space: Spaces.ID, slot: SpaceLayout.Slot)] = [:]
    private var previewCapture: DispatchWorkItem?
    /// Apps with a window `track` passed over for being full screen, to look at again after Space changes.
    private var fullScreenPIDs: Set<pid_t> = []
    /// The frame Spacetile last wrote to each window and when, so the moves it makes itself aren't
    /// taken for macOS tiling.
    private var written: [WindowID: (frame: CGRect, at: Date)] = [:]
    /// Windows something other than Spacetile moved or resized, waiting to be read as macOS tiling
    /// once the moves stop (Fill & Arrange moves several windows one after another).
    private var movedByOthers: Set<WindowID> = []
    private var nativeSettle: DispatchWorkItem?
    /// A window's tile before macOS tiled it, for its Return to Previous Size.
    private var beforeNativeTile: [WindowID: CGRect] = [:]
    private var adoptsNativeTiling = true
    /// Step windows into their tiles on showing Spaces rather than jumping, unless Reduce Motion is on.
    private var animatesWindows = false
    private var fullScreenApps: Set<String> = []
    /// Spaces still owed windows by the last loaded profile, per bundle ID: the next new windows of
    /// that app go there (apps the profile had to launch, or that had fewer windows open).
    private var pendingPlacements: [String: [Spaces.ID]] = [:]
    /// The connected displays, as profiles record them.
    private var lastDisplay = Spaces.desktops.fingerprint
    /// The follow-up status read after a focus change, replaced while changes keep coming.
    private var statusRecheck: DispatchWorkItem?
    /// The pending reaction to a display change, replaced while changes keep coming.
    private var displaySettle: DispatchWorkItem?
    /// Per display, the Space shown before the current one, for `space last`, and the one shown now.
    private var previousSpace: [String: Spaces.ID] = [:]
    private var shownSpace: [String: Spaces.ID] = [:]
    private let preselectOverlay = Overlay()
    /// The focused window's border and the shade behind it, when Settings turns them on.
    private let highlight = FocusHighlight()
    private var floatRules = FloatRules.default
    private var spaceRules = SpaceRules.default
    private(set) var focusFollowsMouse = true
    /// Supplies padding, gap and ratio, automatic unless config.json fixes them.
    private var spacingSettings = Settings.default
    /// How every Space tiles and stacks, from Settings.
    private var tiling = TileAlgorithm.bsp
    private var stacking = StackAlgorithm.fill
    private var mouseFollowsFocus = true
    private var followsSends = true
    private var followsRouting = false
    var onStatusChange: (Status) -> Void = { _ in }
    /// Asked before applying a profile captured in the other Spaces mode; true goes ahead.
    var confirmModeMismatch: (Profile, _ spansNow: Bool) -> Bool = { _, _ in true }
    /// Called when a profile has Spaces with no Desktop to go to, for the app to say so.
    var onProfileWarning: (Profile, [ProfilePlacement]) -> Void = { _, _ in }
    /// The last status published, for the Menu Bar pane's preview.
    private(set) var status = Status()
    /// While paused, windows are still tracked so layouts stay current, but no frame is written, no
    /// rule moves a window and commands are ignored. Resuming lays out the current Space again.
    private(set) var isPaused = false

    func start() {
        // A hung app must not freeze tiling for everyone else
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        // Forgets a last profile deleted or renamed while Spacetile wasn't running
        lastProfileIcon = lastProfile.flatMap { ProfileStore.named($0) }?.symbol
        if lastProfileIcon == nil { lastProfile = nil }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.launched(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.terminated(app.processIdentifier) }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.spaceChanged() }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.focusChanged() }
        }
        // Hidden apps' windows leave the tiling; unhidden ones join next to the focused window
        center.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.hidden(app.processIdentifier) }
        }
        center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.unhidden(app.processIdentifier) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.displaysChanged("displays changed") }
        }
        // Sleep leaves windows where macOS put them while displays were off, like a display change
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.displaysChanged("woke") }
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app.processIdentifier, applyingRules: false)
        }
        spaceChanged()
    }

    /// A display connected, disconnected or rearranged, or the Mac woke: macOS may have moved windows
    /// between displays. Until the displays settle, windows keep their layouts, and then every
    /// Desktop is laid out again. Docking and waking fire several notifications in a row, so the
    /// settled check runs once, 1.5 s after the last.
    func displaysChanged(_ reason: String) {
        log.notice("\(reason, privacy: .public); laying out again once displays settle")
        displaysUnsettled = true
        displaySettle?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.displaysSettled() } }
        displaySettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Applies new settings at once. Space layout modes only affect Spaces laid out from now on.
    func update(_ settings: Settings) {
        floatRules = settings.floatRules
        spaceRules = settings.spaceRules
        focusFollowsMouse = settings.focusFollowsMouse
        mouseFollowsFocus = settings.mouseFollowsFocus
        followsSends = settings.followsSends
        followsRouting = settings.followsRouting
        adoptsNativeTiling = settings.adoptsNativeTiling
        animatesWindows = settings.animatesWindows
        fullScreenApps = settings.fullScreenRules
        let spacingChanged = spacingSettings.padding != settings.padding || spacingSettings.gap != settings.gap
            || spacingSettings.usesSpacing != settings.usesSpacing
        highlight.showsBorder = settings.showsActiveBorder
        highlight.dims = settings.dimsInactive
        highlight.borderColor = settings.borderColor.flatMap(NSColor.init(hex:))
        highlight.borderOpacity = settings.activeBorderOpacity
        highlight.dimOpacity = settings.inactiveDimOpacity
        spacingSettings = settings
        let algorithmsChanged = tiling != settings.tileAlgorithm || stacking != settings.stackAlgorithm
        tiling = settings.tileAlgorithm
        stacking = settings.stackAlgorithm
        if algorithmsChanged {
            for space in layouts.keys {
                layouts[space]?.setTiling(tiling, share: settings.splitRatio)
                layouts[space]?.stacking = stacking
            }
        }
        if spacingChanged || algorithmsChanged { Spaces.desktops.visible.forEach { apply($0) } }
        publishStatus()
    }

    // MARK: - Commands

    func perform(_ command: Command) {
        if command == .togglePause {
            isPaused.toggle()
            log.notice("tiling \(self.isPaused ? "paused" : "resumed", privacy: .public)")
            if isPaused { preselectOverlay.hide() } else { adoptOnScreen() }
            highlight.isSuspended = isPaused
            return spaceChanged()
        }
        guard !isPaused else { return log.notice("\(command.text, privacy: .public): paused") }
        switch command {
        case .retile: return spaceChanged()
        case .focusSpace(let position): return Spaces.switchTo(position: position)
        case .stepSpace(let forward):
            // From a full-screen Space too: the Desktop beside it
            guard let display = Spaces.desktops.active, let next = display.desktop(after: display.current, forward: forward) else { return }
            return Spaces.switchTo(next)
        case .stepFullScreen(let forward):
            guard let display = Spaces.desktops.active, let next = display.fullScreenSpace(after: display.current, forward: forward) else {
                return log.notice("space fullscreen: no full-screen apps on this display")
            }
            return Spaces.switchTo(next)
        case .lastSpace:
            guard let display = Spaces.desktops.active, let previous = previousSpace[display.id], display.order.contains(previous) else { return }
            return Spaces.switchTo(previous)
        case .toggleFullScreen:
            // The window may be full screen already, and so not tracked
            guard let focused = focusedWindow() else { return log.notice("fullscreen: no window has focus") }
            let on = !FullScreen.isOn(focused)
            log.notice("fullscreen \(on ? "on" : "off", privacy: .public) for \(focused.id) \(focused.appName, privacy: .public)")
            if !FullScreen.set(focused, on: on) { log.error("fullscreen: \(focused.appName, privacy: .public) refused") }
            return
        case .fullScreenPair: return fullScreenPair()
        case .focusDisplay(let forward): return focusDisplay(forward: forward)
        case .capture(let name): return capture(name)
        case .load(let name):
            guard let profile = ProfileStore.named(name) else { return log.error("no profile \(name, privacy: .public)") }
            // Captured with Spaces spanning displays and applied with separate Spaces (or the other
            // way round): Desktops line up differently, so ask first
            let desktops = Spaces.desktops
            guard desktops.sameMode(as: profile) || confirmModeMismatch(profile, desktops.spansDisplays) else {
                return log.notice("load \(name, privacy: .public): cancelled, captured in the other Spaces mode")
            }
            return load(profile)
        default: break
        }
        guard let focused = focusedWindow(), windows[focused.id] != nil else {
            return log.notice("\(command.text, privacy: .public): no tracked window has focus")
        }
        let space = Spaces.space(of: focused.id) ?? Spaces.active
        let (bounds, spacing) = tileArea(for: space)
        var layout = layout(for: space)
        // Maximize height keeps the window's own left edge and width: its tile's when tiled, since
        // the frame sits inside the gaps
        var command = command
        if case .place(.column(nil)) = command,
           let frame = layout.tree.contains(focused.id) ? layout.frames(in: bounds, gap: 0)[focused.id] : focused.frame {
            command = .place(.column(span: Region.span(of: frame, in: bounds)))
        }

        switch command {
        case .focus(let direction):
            layout.neighbor(of: focused.id, toward: direction, in: bounds).map(focus)
            return
        case .cycleStack(let forward):
            layout.cycle(from: focused.id, forward: forward).map(focus)
            return
        case .sendToSpace(let position):
            let desktops = Spaces.desktops
            guard let display = desktops.display(of: space), let target = desktops.space(position: position, on: display) else { return }
            guard !display.isFullScreen(target) else { return log.notice("send \(position): a full-screen app's Space, can't take windows") }
            return send(focused, to: target, from: space)
        case .sendStep(let forward):
            return sendToAdjacentSpace(focused.id, forward: forward)
        case .sendToDisplay(let forward):
            let desktops = Spaces.desktops
            guard let from = desktops.display(of: space), let to = desktops.neighbor(of: from, forward: forward) else { return }
            guard !to.isFullScreen(to.current) else { return log.notice("send display: \(to.name, privacy: .public) is showing a full-screen app") }
            return send(focused, to: to.current, from: space)
        case .place(let region) where layout.floating.contains(focused.id) || layout.mode == .float:
            return placeFloating(focused, in: region, bounds: bounds, gap: spacing.gap)
        case .close:
            if let button: AXUIElement = focused.element.value(of: kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            return
        case .swap(let direction): layout.swap(focused.id, toward: direction, in: bounds)
        case let .moveBorder(axis, points): layout.moveBorder(of: focused.id, along: axis, by: points, in: bounds)
        case .toggleZoom: layout.toggleZoom(focused.id)
        case .toggleFloat: layout.toggleFloat(focused.id, beside: lastFocusedTiled[space], in: bounds)
        case .setLayout(let mode): layout.mode = mode
        case .balance: layout.balance()
        case .place(let region): layout.place(focused.id, in: region, bounds: bounds)
        case .resize(let grow): layout.resize(focused.id, grow: grow, in: bounds, gap: spacing.gap, minimumSizes: minimumSizes)
        case .restore: layout.restore(in: bounds)
        case .mirror(let axis): layout.mirror(axis)
        case .rotate(let rotation): layout.rotate(rotation)
        case .preselect(let direction): layout.preselect(direction, beside: focused.id)
        case .join(let direction): layout.join(focused.id, toward: direction, in: bounds, gap: spacing.gap)
        case .popOut: layout.popOut(focused.id, in: bounds)
        case .popIn: layout.popIn()
        case .toggleSplit: layout.toggleSplit(of: focused.id)
        case .retile, .focusSpace, .capture, .load, .stepSpace, .lastSpace, .togglePause, .openSettings, .focusDisplay,
             .toggleFullScreen, .fullScreenPair, .stepFullScreen, .toggle: break
        }
        switch command {
        case .place, .resize, .restore: break
        default: layout.endSizingRun()
        }
        layouts[space] = layout
        apply(space)
    }

    /// Sets the current Space's layout mode. The mini-map uses this: while it's open no tiled window
    /// has focus, which `perform(.setLayout)` needs.
    func setCurrentMode(_ mode: LayoutMode) {
        guard !isPaused else { return }
        let space = Spaces.active
        var layout = layout(for: space)
        layout.mode = mode
        layouts[space] = layout
        apply(space)
    }

    /// Focuses the display beside the focused window's (or the active one): the window last
    /// focused on the Space it's showing, or its first tiled window. An empty Space gets the pointer
    /// instead, which makes its display the active one.
    private func focusDisplay(forward: Bool) {
        let desktops = Spaces.desktops
        let here = desktops.displays.first { $0.id == emptyDisplay }
            ?? focusedWindow().flatMap { Spaces.space(of: $0.id) }.flatMap(desktops.display(of:)) ?? desktops.active
        guard let from = here, let to = desktops.neighbor(of: from, forward: forward) else {
            return log.notice("focus display: nothing to do, \(here == nil ? "no active display" : "\(desktops.displays.count) display(s)", privacy: .public)")
        }
        let layout = layouts[to.current]
        let candidates = [lastFocusedTiled[to.current]].compactMap { $0 } + (layout?.tree.windows ?? []) + Array(layout?.floating ?? [])
        // The pointer goes too: the display under it is the one the menu bar and ⌥N act on
        if let window = candidates.lazy.compactMap({ self.windows[$0] }).first {
            log.notice("focus display \(to.name, privacy: .public): window \(window.id)")
            emptyDisplay = nil
            Focus.focus(window)
            let frame = window.frame ?? to.frame
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        } else {
            log.notice("focus display \(to.name, privacy: .public): empty, moving the pointer there")
            emptyDisplay = to.id
            CGWarpMouseCursorPosition(CGPoint(x: to.frame.midX, y: to.frame.midY))
        }
    }

    /// Puts the focused tiled window and its neighbour into Split View, each on the side it's on
    /// now. Split View has no API: Spacetile presses the app's Window ▸ Full-Screen Tile item, which
    /// makes the window full screen on that side, and macOS then asks which window goes beside it;
    /// Spacetile clicks the partner there. Leaving full screen puts both back in their tiles.
    private func fullScreenPair() {
        guard let focused = focusedWindow(), let space = layoutSpace(of: focused.id), let layout = layouts[space],
              layout.tree.contains(focused.id) else { return log.notice("fullscreen pair: no tiled window has focus") }
        let (bounds, spacing) = tileArea(for: space)
        let frames = layout.frames(in: bounds, gap: spacing.gap)
        // Its split partner when that's one window, otherwise the nearest tile beside it
        var candidate: WindowID?
        if case let .tiled(.split(_, _, _, siblings))? = layout.slot(of: focused.id), siblings.count == 1, !BSPTree.isHole(siblings[0]) {
            candidate = siblings[0]
        }
        candidate = candidate ?? [Direction.east, .west, .south, .north].lazy.compactMap { layout.neighbor(of: focused.id, toward: $0, in: bounds) }.first
        guard let partner = candidate, let other = windows[partner], let mine = frames[focused.id], let theirs = frames[partner] else {
            return log.notice("fullscreen pair: \(focused.id) has no neighbour to pair with")
        }
        let left = mine.midX <= theirs.midX
        guard FullScreen.tile(pid: focused.pid, left: left) else {
            log.notice("fullscreen pair: \(focused.appName, privacy: .public) has no Full Screen Tile menu item")
            return notice.flash(mine, as: .refused("\(focused.appName) can't go full screen beside another window"), for: 3)
        }
        log.notice("fullscreen pair: \(focused.id) \(left ? "left" : "right", privacy: .public) beside \(partner) \(other.appName, privacy: .public)")
        guard let display = Spaces.desktops.display(of: space)?.frame else { return }
        finishPair(with: other, farHalfOf: display, left: left)
    }

    /// Chooses `partner` in the Split View picker macOS lays out on the far half, or points it out
    /// when its thumbnail doesn't turn up.
    private func finishPair(with partner: AXWindow, farHalfOf display: CGRect, left: Bool) {
        let far = CGRect(x: left ? display.midX : display.minX, y: display.minY, width: display.width / 2, height: display.height)
        FullScreen.choose(partner.id, in: far) { chose in
            guard !chose else { return }
            log.notice("fullscreen pair: no thumbnail for \(partner.id) to choose")
            self.notice.flash(far, as: .hint("Choose \(partner.appName) to finish"), for: 4)
        }
    }

    private func focus(_ id: WindowID) {
        guard let window = windows[id] else { return }
        Focus.focus(window)
        moveMouse(into: window)
    }

    /// Places a floating window as Raycast would: a plain frame. Repeating an edge cycles ½ → ⅔ → ⅓
    /// by recognising which cycle size the window already has.
    private func placeFloating(_ window: AXWindow, in region: Region, bounds: CGRect, gap: CGFloat) {
        var fraction = Region.cycle[0]
        if case .edge(_, nil) = region, let frame = window.frame,
           let index = Region.cycle.firstIndex(where: { region.rect(in: bounds, gap: gap, fraction: $0).integral == frame.integral }) {
            fraction = Region.cycle[(index + 1) % Region.cycle.count]
        }
        window.setFrame(region.rect(in: bounds, gap: gap, fraction: fraction))
    }

    /// Moves the window to another Space and lays out both Spaces (the target through the kept AX
    /// handle while it's still hidden). With "Follow after sending" on, switches there and
    /// refocuses the window.
    private func send(_ window: AXWindow, to target: Spaces.ID, from source: Spaces.ID) {
        guard target != source else { return }
        Spaces.move(window.id, to: target)
        relocate(window.id, from: source, to: target)
        if followsSends { Spaces.switchTo(target) { self.focus(window.id) } }
    }

    /// Moves a window's layout membership between Spaces, keeping float state.
    private func relocate(_ id: WindowID, from source: Spaces.ID, to target: Spaces.ID) {
        let wasFloating = layouts[source]?.floating.contains(id) ?? false
        layouts[source]?.remove(id)
        if lastFocusedTiled[source] == id { lastFocusedTiled[source] = nil }
        let (bounds, spacing) = tileArea(for: target)
        var layout = layout(for: target)
        layout.add(id, app: windows[id]?.bundleID, beside: lastFocusedTiled[target], in: bounds, gap: spacing.gap,
                   floating: wasFloating, ratio: spacing.ratio, minimumSizes: minimumSizes)
        layouts[target] = layout
        apply(source)
        apply(target)
    }

    // MARK: - Mouse

    /// The window under `point` (AX coordinates) if Spacetile tracks it. The topmost normal window
    /// decides: over a dialog or another untracked window this is nil, not the tile behind it.
    func window(at point: CGPoint) -> AXWindow? {
        onScreenWindows().first { $0.bounds.contains(point) }.flatMap { windows[$0.id] }
    }

    /// Tracked windows whose bounds, widened by `slack`, contain `point`, front to back. For edge
    /// grabs, which land in the gap between two windows.
    func windows(near point: CGPoint, slack: CGFloat) -> [AXWindow] {
        onScreenWindows().filter { $0.bounds.insetBy(dx: -slack, dy: -slack).contains(point) }.compactMap { windows[$0.id] }
    }

    /// Other apps' normal-layer windows on screen, front to back. Spacetile's own border and shade
    /// sit on that layer too, and the pointer goes through them.
    private func onScreenWindows() -> [(id: WindowID, bounds: CGRect)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard entry[kCGWindowLayer as String] as? Int == 0, entry[kCGWindowOwnerPID as String] as? pid_t != getpid(),
                  let id = entry[kCGWindowNumber as String] as? WindowID,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return (id, bounds)
        }
    }

    /// The Space whose layout holds a window. Mouse paths use this rather than the window server,
    /// which reports a window straddling two displays mid-drag as on no single Space.
    private func layoutSpace(of id: WindowID) -> Spaces.ID? {
        layouts.first { $0.value.contains(id) }?.key
    }

    func isTiled(_ id: WindowID) -> Bool { layoutSpace(of: id).flatMap { layouts[$0] }?.tree.contains(id) == true }

    /// Where the layout puts a tiled window on its Space.
    func tileFrame(of id: WindowID) -> CGRect? {
        guard let space = layoutSpace(of: id) else { return nil }
        let (bounds, spacing) = tileArea(for: space)
        return layouts[space]?.frames(in: bounds, gap: spacing.gap)[id]
    }

    /// Where a window dragged to `point` lands: the Space showing on the display under the point,
    /// and that Space's layout with the window in it, for working out the drop.
    private func dropTarget(_ id: WindowID, at point: CGPoint) -> (space: Spaces.ID, layout: SpaceLayout, display: DisplaySpaces)? {
        let desktops = Spaces.desktops
        guard let source = layoutSpace(of: id), let display = desktops.display(containing: point) else { return nil }
        let target = display.current
        // A full-screen app fills that display: nothing to drop into
        guard !display.isFullScreen(target) else { return nil }
        var layout = layout(for: target)
        if target != source {
            // Dragged onto another display: work out the drop as if the window were already there
            let (bounds, spacing) = tileArea(for: target)
            layout.add(id, beside: nil, in: bounds, gap: spacing.gap, minimumSizes: minimumSizes)
        }
        return (target, layout, display)
    }

    /// Where dropping a dragged tiled window at `point` would put it, and what that would do, for the overlay.
    func dropHighlight(dragging id: WindowID, at point: CGPoint) -> (rect: CGRect, kind: Overlay.Kind)? {
        guard let target = dropTarget(id, at: point) else { return nil }
        let (bounds, spacing) = tileArea(for: target.space)
        guard let drop = target.layout.drop(id, at: point, in: bounds, gap: spacing.gap) else {
            // An empty Space on another display: the window would fill it
            let moving = layoutSpace(of: id) != target.space
            return moving ? (bounds, .moveToDisplay(target.display.name)) : nil
        }
        let kind: Overlay.Kind = switch drop.action {
        case .swap(let other) where BSPTree.isHole(other): .fillHole
        case .swap(let other): .swap(with: windows[other]?.appName ?? "window")
        case let .insert(other, side): .insert(side, beside: windows[other]?.appName ?? "window")
        }
        return (drop.highlight, kind)
    }

    /// The Desktop before or after the window's on its display, skipping full-screen Spaces and
    /// wrapping round, and its position for the send-to-edge label.
    func adjacentDesktop(of id: WindowID, forward: Bool) -> (space: Spaces.ID, position: Int)? {
        let desktops = Spaces.desktops
        guard let space = layoutSpace(of: id) ?? Spaces.space(of: id), let display = desktops.display(of: space),
              display.spaces.contains(space), let next = display.desktop(after: space, forward: forward),
              let position = desktops.position(of: next) else { return nil }
        return (next, position)
    }

    /// Re-tiles a dragged window: swaps or inserts it where it was dropped, moving it to that
    /// display's Space if it was dragged onto another display, otherwise snaps it back.
    func drop(_ id: WindowID, at point: CGPoint) {
        guard let source = layoutSpace(of: id), let target = dropTarget(id, at: point) else { return }
        let (bounds, spacing) = tileArea(for: target.space)
        let crossing = target.space != source
        // Where the window came from, for a swap to send the other window back to
        let slot = crossing ? layouts[source]?.slot(of: id) : nil
        if crossing {
            log.notice("drop \(id) onto \(target.display.name, privacy: .public)")
            Spaces.move(id, to: target.space)
            relocate(id, from: source, to: target.space)
        }
        if let drop = target.layout.drop(id, at: point, in: bounds, gap: spacing.gap) {
            layouts[target.space]?.perform(drop.action, dragging: id, in: bounds, gap: spacing.gap)
            log.notice("drop \(id): \(String(describing: drop.action), privacy: .public)")
            if case .insert = drop.action { explainIfStacked(id, in: target.space) }
            // Across displays a swap trades places: the other window takes this one's old spot
            if crossing, case .swap(let other) = drop.action, !BSPTree.isHole(other) {
                layouts[target.space]?.remove(other)
                Spaces.move(other, to: source)
                var back = layout(for: source)
                if !(slot.map { back.reinsert(other, at: $0) } ?? false) {
                    let (sourceBounds, sourceSpacing) = tileArea(for: source)
                    back.add(other, beside: nil, in: sourceBounds, gap: sourceSpacing.gap, minimumSizes: minimumSizes)
                }
                layouts[source] = back
                apply(source)
            }
        }
        apply(target.space)
    }

    /// A drop meant to split a tile that ended up stacked instead: says which window's minimum size
    /// left no room, over the tile, so the drop doesn't look ignored.
    private func explainIfStacked(_ id: WindowID, in space: Spaces.ID) {
        let (bounds, spacing) = tileArea(for: space)
        var layout = layout(for: space)
        layout.normalize(in: bounds, gap: spacing.gap, minimumSizes: minimumSizes)
        let stack = layout.tree.stack(containing: id)
        guard stack.count > 1, let rect = layout.frames(in: bounds, gap: spacing.gap)[id] else { return }
        // The window with the largest minimum is the one that wouldn't fit
        guard let blocker = stack.compactMap({ other in minimumSizes[other].map { (other, $0) } })
            .max(by: { max($0.1.width, $0.1.height) < max($1.1.width, $1.1.height) }) else { return }
        let name = windows[blocker.0]?.appName ?? "A window"
        // Only the limits it has: a window can be bound in one direction alone
        let needs = [blocker.1.width > 0 ? "\(Int(blocker.1.width)) pt wide" : nil,
                     blocker.1.height > 0 ? "\(Int(blocker.1.height)) pt tall" : nil].compactMap { $0 }.joined(separator: " and ")
        let reason = "No room to split: \(name) needs to be at least \(needs)"
        log.notice("drop \(id): stacked, \(reason, privacy: .public)")
        notice.flash(rect, as: .refused(reason))
    }

    /// A tiled window the user resized by its edges: each moved edge moves the split it sits on,
    /// then the layout is re-applied so the neighbours follow. While the drag is `live` the window
    /// itself isn't written, so it doesn't fight the pointer.
    func userResized(_ id: WindowID, live: Bool = false) {
        guard let space = layoutSpace(of: id) else { return }
        let (bounds, spacing) = tileArea(for: space)
        guard let layout = layouts[space], let target = layout.frames(in: bounds, gap: spacing.gap)[id],
              let actual = windows[id]?.frame else { return }
        let edges: [(Direction, CGFloat)] = [
            (.west, actual.minX - target.minX), (.east, actual.maxX - target.maxX),
            (.north, actual.minY - target.minY), (.south, actual.maxY - target.maxY),
        ]
        for (edge, delta) in edges where abs(delta) > 2 {
            layouts[space]?.moveEdge(edge, of: id, by: delta, in: bounds)
            if !live { log.notice("resize \(id): \(String(describing: edge), privacy: .public) edge by \(Int(delta))") }
        }
        apply(space, skipping: live ? id : nil, learning: !live)
    }

    /// Focus follows mouse. Focuses without raising, so a floating window stays in front of the
    /// tile under the pointer. (Raising floats back up afterwards can't work with SIP on: a
    /// background app's window only rises among its own app's windows.) Skips the window that's
    /// already focused.
    func focusUnderMouse(_ window: AXWindow) {
        let current = focusedWindow()
        guard current?.id != window.id else { return }
        Focus.focusWithoutRaise(window, current: current)
    }

    // MARK: - Tracking

    private func launched(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        observe(app.processIdentifier, applyingRules: true)
        // Slow launchers create windows before their AX server answers; catch them on a second look
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.observe(app.processIdentifier, applyingRules: true)
            }
        }
    }

    private func hidden(_ pid: pid_t) {
        for window in windows.values where window.pid == pid { removeFromLayouts(window.id) }
    }

    private func unhidden(_ pid: pid_t) {
        for window in windows.values where window.pid == pid { layoutIfTileable(window) }
    }

    private func terminated(_ pid: pid_t) {
        observers[pid] = nil
        savedSlots = savedSlots.filter { $0.value.pid != pid }
        for window in windows.values where window.pid == pid { untrack(window.id) }
    }

    /// Attaches the app observer if missing, then picks up any of its windows on the current Space.
    private func observe(_ pid: pid_t, applyingRules: Bool) {
        // Spacetile's own windows (Settings, Profiles) show while it's a regular app; never tile them
        guard pid != getpid() else { return }
        if observers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
            let app = AXUIElementCreateApplication(pid)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                AXObserverAddNotification(observer, app, name as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
        for window in AXUIElement.windows(of: pid) { track(window, applyingRules: applyingRules) }
    }

    private func track(_ window: AXWindow, applyingRules: Bool) {
        // Full screen, or still on its full-screen Space while leaving: tracked now it would never be
        // laid out, so wait; the Space change on leaving looks again
        if window.element.value(of: "AXFullScreen") == true || Spaces.space(of: window.id).map(Spaces.desktops.isFullScreen) == true {
            fullScreenPIDs.insert(window.pid)
            return
        }
        guard register(window) else { return }
        layoutIfTileable(window, applyingRules: applyingRules)
    }

    /// Starts watching a standard window without laying it out. False if it's tracked already or
    /// isn't one Spacetile manages.
    private func register(_ window: AXWindow) -> Bool {
        guard windows[window.id] == nil, window.element.value(of: kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
              let observer = observers[window.pid] else { return false }
        windows[window.id] = window
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Moves and resizes are for reading macOS's own tiling
        for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, window.element, name as CFString, refcon)
        }
        return true
    }

    /// Adds a tracked window to its Space's layout, floating it when a rule says so. New windows of
    /// apps with a Space rule are moved there first; Spacetile stays on the current Space.
    private func layoutIfTileable(_ window: AXWindow, applyingRules: Bool = false) {
        guard window.isTileable else { return }
        var space = Spaces.space(of: window.id) ?? Spaces.active
        var routedByRule = false
        // Only full-screen windows belong on a full-screen app's Space; anything else there floats
        guard !Spaces.desktops.isFullScreen(space) else { return }
        if applyingRules, !isPaused, let (target, byRule) = placement(for: window), target != space {
            space = target
            routedByRule = byRule
            Spaces.move(window.id, to: space)
        }
        let floats = floatRules.floats(app: window.appName, title: window.title)
        let (bounds, spacing) = tileArea(for: space)
        var layout = layout(for: space)
        if let saved = savedSlots.removeValue(forKey: window.id), saved.space == space, layout.reinsert(window.id, at: saved.slot) {
            log.notice("window \(window.id) back in its old place")
        } else {
            layout.add(window.id, app: window.bundleID, beside: lastFocusedTiled[space], in: bounds, gap: spacing.gap,
                       floating: floats, ratio: spacing.ratio, minimumSizes: minimumSizes)
        }
        layouts[space] = layout
        log.notice("tracked \(window.id) \(window.appName, privacy: .public) on space \(Spaces.number(of: space) ?? 0) floating=\(floats)")
        apply(space)
        if routedByRule, followsRouting {
            Spaces.switchTo(space) { self.focus(window.id) }
        }
        // A full-screen rule goes after any Desktop rule, so the app's Space lands after that Desktop.
        // Tiled first, so leaving full screen puts it back in a tile
        if applyingRules, !isPaused, fullScreenApps.contains(window.appName) {
            log.notice("rule: \(window.appName, privacy: .public) opens full screen")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { FullScreen.set(window, on: true) }
        }
        // The window's own focus event usually arrives before it was tracked, so re-read focus now
        focusChanged()
    }

    /// Where a newly created window should go: a Space the loaded profile still owes its app,
    /// otherwise the app's Space rule. `byRule` tells the two apart, since only rules can follow.
    private func placement(for window: AXWindow) -> (space: Spaces.ID, byRule: Bool)? {
        if let owed = pendingPlacements[window.bundleID], let next = owed.first {
            pendingPlacements[window.bundleID] = Array(owed.dropFirst())
            log.notice("profile owes \(window.bundleID, privacy: .public) desktop \(Spaces.number(of: next) ?? 0): routing window \(window.id)")
            return (next, false)
        }
        // A rule's Desktop number is on the active display, as ⌥N is
        let desktops = Spaces.desktops
        return spaceRules.apps[window.appName].flatMap { number in
            desktops.active.flatMap { desktops.space(number: number, on: $0) }.map { ($0, true) }
        }
    }

    // MARK: - Profiles

    /// Regular apps' windows on any Space, including Spaces not visited since launch and full-screen
    /// apps' Spaces. Profiles number each app's windows over all of these, so a window keeps its
    /// ref whether it's full screen or not.
    private func allWindows() -> [(id: WindowID, app: String, space: Spaces.ID)] {
        allWindowsWithBounds(fullScreen: true).map { ($0.id, $0.app, $0.space) }
    }

    /// As `allWindows`, front to back, with each window's bounds and owner. Windows in full-screen
    /// apps' Spaces too, with `fullScreen`.
    private func allWindowsWithBounds(fullScreen: Bool = false) -> [(id: WindowID, app: String, space: Spaces.ID, bounds: CGRect, pid: pid_t)] {
        let current = Spaces.desktops
        let desktops = Set(fullScreen ? current.displays.flatMap(\.order) : current.allSpaces)
        let displays = Self.displayBounds()
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? WindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  // Skips the invisible helper windows many apps keep around
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.width >= 100, bounds.height >= 100, Self.mostlyOnScreen(bounds, displays),
                  let space = Spaces.space(of: id, bounds: bounds), desktops.contains(space),
                  // A full-screen Space also holds the app's toolbar strips and helpers: keep its tiles
                  current.tiles(of: space)?.windows.contains(id) ?? true else { return nil }
            return (id, bundleID, space, bounds, pid)
        }
    }

    // MARK: - Mini-map

    /// One display's row in the mini-map.
    struct MiniDisplay: Identifiable {
        let id: String
        let name: String
        /// Where the display sits, for drawing the arrangement.
        let frame: CGRect
        /// Width over height, which every card on the display takes.
        let aspect: CGFloat
        let isActive: Bool
        let spaces: [MiniSpace]
        /// Where each display sits within a card, as fractions of it, when one card covers several
        /// displays (Spaces spanning displays). Empty when a card is one display.
        var panels: [CGRect] = []
        /// The display each panel shows, for its wallpaper.
        var panelDisplays: [String] = []
    }

    struct MiniSpace: Identifiable {
        let id: Spaces.ID
        /// Position on its display in Mission Control order, full-screen Spaces counted, as ⌥N takes it.
        let number: Int
        /// The Desktop's label; Desktops keep theirs when a full-screen app opens before them.
        let label: String?
        /// Showing on its display.
        let isCurrent: Bool
        /// Back to front, so later windows draw on top.
        let windows: [MiniWindow]
        /// Each display's part of the Desktop, in the order of the card's panels, when one card
        /// covers several displays.
        var panelSpaces: [Spaces.ID] = []
        /// A full-screen app's Space rather than a Desktop. Its windows, left first, are the app
        /// (or two side by side in Split View).
        var isFullScreen = false

        /// "Safari" or "Safari · Notes", for a full-screen card's caption.
        var appNames: String {
            windows.sorted { $0.rect.minX < $1.rect.minX }
                .compactMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName }.joined(separator: " · ")
        }
    }

    struct MiniWindow: Identifiable {
        let id: WindowID
        let pid: pid_t
        /// Position on the display as fractions of its size.
        let rect: CGRect
        /// Taken out of the tiling with float (or by a rule), so it keeps its own frame.
        let isFloating: Bool
    }

    /// Every window's bounds, by window number, from one read of the window list.
    private static func windowBounds() -> [WindowID: CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Dictionary(info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? WindowID,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return (id, bounds)
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Connected displays in the window server's top-left coordinates, the ones window bounds use.
    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map(CGDisplayBounds)
    }

    /// Whether at least half of a window is on one display. Apps keep invisible helper windows
    /// sized for displays long gone; macOS moves real windows back on screen when a display goes.
    private static func mostlyOnScreen(_ bounds: CGRect, _ displays: [CGRect]) -> Bool {
        let area = bounds.width * bounds.height
        return displays.contains { display in
            let overlap = display.intersection(bounds)
            return !overlap.isNull && overlap.width * overlap.height >= area / 2
        }
    }

    /// Every tracked window's app and title, for checking title rules against what's open.
    func windowTitles() -> [(app: String, title: String)] {
        windows.values.map { ($0.appName, $0.title) }
    }

    /// Every display's Spaces with their windows where the window server has them, visited or not.
    func miniMap() -> [MiniDisplay] {
        let all = allWindowsWithBounds(fullScreen: true)
        let desktops = Spaces.desktops
        /// A Space's windows, placed as fractions of `area`. On a Space Spacetile has laid out, only
        /// the windows it manages: apps keep invisible full-size helper windows that would otherwise
        /// cover real ones in the map.
        func windows(on space: Spaces.ID, in area: CGRect) -> [MiniWindow] {
            let laidOut = layouts[space]
            return all.filter { $0.space == space && (laidOut == nil || laidOut!.contains($0.id)) }.reversed().map { window in
                MiniWindow(id: window.id, pid: window.pid,
                           rect: CGRect(x: (window.bounds.minX - area.minX) / area.width, y: (window.bounds.minY - area.minY) / area.height,
                                        width: window.bounds.width / area.width, height: window.bounds.height / area.height),
                           isFloating: laidOut?.floating.contains(window.id) == true)
            }
        }
        // Spaces spanning displays: one card per Desktop, showing every display where it sits
        if desktops.spansDisplays, desktops.displays.count > 1, let first = desktops.displays.first {
            let area = desktops.displays.reduce(CGRect.null) { $0.union($1.frame) }
            // Every display lists the same Spaces in the same order; full-screen ones keep one ID
            let spaces = first.order.enumerated().map { position, space -> MiniSpace in
                guard let index = first.spaces.firstIndex(of: space) else {
                    return MiniSpace(id: space, number: position + 1, label: nil, isCurrent: space == first.current,
                                     windows: windows(on: space, in: area), isFullScreen: true)
                }
                return MiniSpace(id: space, number: position + 1, label: spaceRules.labels[index + 1],
                                 isCurrent: space == first.current,
                                 windows: desktops.displays.flatMap { windows(on: $0.spaces[index], in: area) },
                                 panelSpaces: desktops.displays.map { $0.spaces[index] })
            }
            let panels = desktops.displays.map {
                CGRect(x: ($0.frame.minX - area.minX) / area.width, y: ($0.frame.minY - area.minY) / area.height,
                       width: $0.frame.width / area.width, height: $0.frame.height / area.height)
            }
            return [MiniDisplay(id: "spanning", name: "All displays", frame: area, aspect: area.width / max(area.height, 1),
                                isActive: true, spaces: spaces, panels: panels, panelDisplays: desktops.displays.map(\.id))]
        }
        return desktops.displays.map { display in
            // Full-screen apps' Spaces sit between the Desktops, as Mission Control shows them
            let spaces = display.order.enumerated().map { position, space -> MiniSpace in
                let desktop = display.spaces.firstIndex(of: space).map { $0 + 1 }
                return MiniSpace(id: space, number: position + 1, label: desktop.flatMap { spaceRules.labels[$0] }, isCurrent: space == display.current,
                                 windows: windows(on: space, in: display.frame), isFullScreen: desktop == nil)
            }
            return MiniDisplay(id: display.id, name: display.name, frame: display.frame, aspect: display.frame.width / max(display.frame.height, 1),
                               isActive: display.id == desktops.active?.id, spaces: spaces)
        }
    }

    /// Sends any window to a Space, on any display, without following it. Windows Spacetile hasn't
    /// seen yet are just moved; they tile when their new Space is visited. With `keepingDisplay`, a
    /// window sent to a Desktop spanning displays stays on its own display.
    func send(_ id: WindowID, to target: Spaces.ID, keepingDisplay: Bool = true) {
        // The window server lays out full-screen apps' Spaces itself
        guard let source = Spaces.space(of: id), !Spaces.desktops.isFullScreen(target), !Spaces.desktops.isFullScreen(source) else { return }
        var target = target
        if keepingDisplay, let from = SpanningSpace.decode(source), let to = SpanningSpace.decode(target) {
            target = SpanningSpace.id(space: to.space, display: from.display)
        }
        guard target != source else { return }
        Spaces.move(id, to: target)
        if layouts[source]?.contains(id) == true { relocate(id, from: source, to: target) }
    }

    /// Sends a window to the Desktop before or after its own, on its display, wrapping round.
    func sendToAdjacentSpace(_ id: WindowID, forward: Bool) {
        guard let window = windows[id], let source = Spaces.space(of: id),
              let target = adjacentDesktop(of: id, forward: forward) else { return }
        send(window, to: target.space, from: source)
    }

    #if SPACETILE_DEV
    /// Development aid: asks the window to be 300×300 at its current origin, logs what it reports
    /// after 0.1 s and 0.5 s (a slow app may still be resizing at the first), then lays its Space out again.
    func measureMinimumSize(of id: WindowID) {
        guard let window = windows[id], let start = window.frame else { return log.notice("min-size \(id): not tracked") }
        window.setFrame(CGRect(origin: start.origin, size: CGSize(width: 300, height: 300)))
        for delay in [0.1, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let size = window.frame?.size ?? .zero
                log.notice("min-size \(id) \(window.appName, privacy: .public) after \(delay)s: \(Int(size.width))x\(Int(size.height))")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            Spaces.space(of: id).map { self.apply($0) }
        }
    }
    #endif

    /// Switches to the window's Space, then focuses it.
    func show(_ id: WindowID) {
        guard let space = Spaces.space(of: id) else { return }
        Spaces.switchTo(space) {
            // A window first seen on arrival is tracked by the Space change; look it up then
            if let window = self.windows[id] { Focus.focus(window) }
        }
    }

    /// Saves every Space's arrangement: laid-out Spaces with their tree, others as plain placements.
    /// `makeCurrent` marks it as the profile applied last, as saving from the mini-map does.
    /// Saves the current layout as profile `name`. A profile with that name already takes the new
    /// layout and keeps its settings; a name that would share another profile's file is refused.
    func capture(_ name: String, makeCurrent: Bool = false) {
        let profiles = ProfileStore.all
        if let existing = profiles.first(where: { $0.name == name }) { return recapture(existing, makeCurrent: makeCurrent) }
        if let problem = profileNameProblem(name, taken: Set(profiles.map(\.name))) {
            log.error("capture \(name, privacy: .public): \(problem, privacy: .public)")
            return refuse("Can't save profile: \(problem)")
        }
        let profile = snapshotProfile(name)
        save(profile)
        if makeCurrent { self.makeCurrent(profile) }
    }

    /// Replaces a profile's windows and layouts with the current ones, keeping its other settings.
    func recapture(_ profile: Profile, makeCurrent: Bool = false) {
        var updated = profile
        let fresh = snapshotProfile(profile.name)
        updated.spaces = fresh.spaces
        updated.displays = fresh.displays
        updated.spansDisplays = fresh.spansDisplays
        updated.fullScreen = fresh.fullScreen
        save(updated)
        if makeCurrent { self.makeCurrent(updated) }
    }

    /// The windows are arranged as `profile` says now, by applying or saving it.
    func makeCurrent(_ profile: Profile) {
        lastProfile = profile.name
        lastProfileIcon = profile.symbol
        publishStatus()
    }

    /// After profiles are edited: follows a rename, picks up a new icon, and forgets one trashed.
    func profilesChanged(_ profiles: [Profile], renamed: (from: String, to: String)? = nil) {
        guard let name = lastProfile else { return }
        if let renamed, name == renamed.from { lastProfile = renamed.to }
        let icon = profiles.first { $0.name == lastProfile }?.symbol
        if icon == nil { lastProfile = nil }
        guard lastProfile != name || icon != lastProfileIcon else { return }
        lastProfileIcon = icon
        publishStatus()
    }

    private func save(_ profile: Profile) {
        do {
            try ProfileStore.save(profile)
            log.notice("saved profile \(profile.name, privacy: .public): \(profile.spaces.count) Spaces")
        } catch {
            log.error("saving profile \(profile.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            refuse("Couldn't save profile “\(profile.name)”")
        }
    }

    /// Says why a command did nothing, in the middle of the active display.
    private func refuse(_ reason: String) {
        guard let frame = Spaces.desktops.active?.frame else { return }
        notice.flash(CGRect(x: frame.midX - 220, y: frame.midY - 60, width: 440, height: 120), as: .refused(reason), for: 3)
    }

    private func snapshotProfile(_ name: String) -> Profile {
        let withBounds = allWindowsWithBounds(fullScreen: true)
        let all = withBounds.map { (id: $0.id, app: $0.app, space: $0.space) }
        let refs = SpacetileCore.WindowRef.assign(all.map { ($0.id, $0.app) })
        let desktops = Spaces.desktops
        // Each Space records its display, so a profile puts windows back on the display they came from
        let snapshots = desktops.displays.flatMap { display in
            display.spaces.enumerated().compactMap { index, space -> SpaceSnapshot? in
                let here = all.filter { $0.space == space }
                guard !here.isEmpty else { return nil }
                let layout = layout(for: space)
                let others = here.filter { !layout.contains($0.id) }.compactMap { refs[$0.id] }
                var snapshot = layout.snapshot(space: index + 1, others: others) { refs[$0] }
                snapshot.display = display.identity.signature
                return snapshot
            }
        }
        let displays = desktops.displays.map { ProfileDisplay(identity: $0.identity, frame: $0.frame, desktops: $0.spaces.count) }
        let fullScreen = fullScreenSnapshots(desktops, windows: withBounds, refs: refs)
        return Profile(name: name, display: desktops.fingerprint, displays: displays,
                       spansDisplays: desktops.spansDisplays ? true : nil, spaces: snapshots,
                       fullScreen: fullScreen.isEmpty ? nil : fullScreen)
    }

    /// Each full-screen app's Space in Mission Control order: its windows, left first. With Spaces
    /// spanning displays every display lists it, so each is taken once.
    private func fullScreenSnapshots(_ desktops: Desktops, windows all: [(id: WindowID, app: String, space: Spaces.ID, bounds: CGRect, pid: pid_t)],
                                     refs: [WindowID: SpacetileCore.WindowRef]) -> [FullScreenSnapshot] {
        var seen = Set<Spaces.ID>()
        return desktops.displays.flatMap(\.fullScreenSpaces).compactMap { space -> FullScreenSnapshot? in
            guard seen.insert(space).inserted else { return nil }
            let windowRefs = all.filter { $0.space == space }.sorted { $0.bounds.minX < $1.bounds.minX }.compactMap { refs[$0.id] }
            return windowRefs.isEmpty ? nil : FullScreenSnapshot(windows: Array(windowRefs.prefix(2)))
        }
    }

    /// Moves every window the profile names to its Space and restores captured layouts. Windows
    /// Spacetile hasn't seen yet are moved now and slot into the captured layout when they're first
    /// tracked. Apps that aren't running are launched and their windows placed as they appear.
    /// Running apps a profile doesn't mention: what it hides or quits. Finder and Spacetile are never among them.
    static func unlistedApps(for profile: Profile) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !profile.launchedApps.contains($0.bundleIdentifier ?? "")
                && $0 != .current && $0.bundleIdentifier != "com.apple.finder"
        }
    }

    func load(_ profile: Profile) {
        lastProfile = profile.name
        lastProfileIcon = profile.symbol
        let interval = signposter.beginInterval("Load profile")
        defer { signposter.endInterval("Load profile", interval) }
        let all = allWindows()
        let live = liveRefs(all)
        let currentSpace = Dictionary(all.map { ($0.id, $0.space) }, uniquingKeysWith: { a, _ in a })
        // Each Space goes back to its display, or after the main display's own Desktops when its
        // display isn't connected, as macOS merges them; Spaces with no Desktop to go to are left
        let placements = Spaces.desktops.place(profile)
        for placement in placements where placement.reason != .matched {
            log.notice("profile \(profile.name, privacy: .public) desktop \(placement.snapshot.space): \(String(describing: placement.reason), privacy: .public), desktop \(placement.number) of \(placement.display?.name ?? "?", privacy: .public)")
        }
        let placed = placements.compactMap { placement in placement.space.map { (placement.snapshot, $0) } }
        let unplaced = placements.filter { $0.space == nil }
        if !unplaced.isEmpty { onProfileWarning(profile, unplaced) }
        var touched = Set<Spaces.ID>()
        pendingPlacements = [:]

        for (snapshot, target) in placed {
            for ref in snapshot.windows {
                guard let id = live[ref] else {
                    pendingPlacements[ref.app, default: []].append(target)
                    continue
                }
                guard let source = currentSpace[id], source != target else { continue }
                // A full-screen window can't be moved to a Desktop; it stays until it leaves full screen
                guard !Spaces.desktops.isFullScreen(source) else {
                    log.notice("profile \(profile.name, privacy: .public): \(ref.app, privacy: .public)#\(ref.index) is full screen, left where it is")
                    continue
                }
                Spaces.move(id, to: target)
                layouts[source]?.remove(id)
                touched.insert(source)
            }
        }
        for (snapshot, target) in placed { restore(snapshot, on: target, live: live) }
        for space in touched { apply(space) }

        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in profile.launchedApps.subtracting(running.compactMap(\.bundleIdentifier)) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            // Only apps this launches get the profile's items, handed over as the app opens, so they
            // add to the windows and tabs it restores rather than replace them
            let items = profile.items(opening: app).compactMap(Self.url(for:))
            if items.isEmpty {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } else {
                log.notice("profile \(profile.name, privacy: .public): launching \(app, privacy: .public) with \(items.count) items")
                NSWorkspace.shared.open(items, withApplicationAt: url, configuration: configuration)
            }
        }
        let unlisted = Self.unlistedApps(for: profile)
        if profile.quitUnlisted == true, !unlisted.isEmpty {
            if QuitConfirmation.confirm(unlisted, for: profile) { unlisted.forEach { $0.terminate() } }
        } else if profile.hideUnlisted == true {
            unlisted.forEach { $0.hide() }
        }
        log.notice("loaded profile \(profile.name, privacy: .public); \(self.pendingPlacements.values.joined().count) windows to launch")
        restoreFullScreen(profile.fullScreen ?? [], of: profile, live: live) {
            if let show = profile.show { Spaces.switchTo(space: show) }
            self.publishStatus()
        }
        publishStatus()
    }

    /// What to hand an app for one of a profile's `open` lines. A command becomes a script that runs
    /// it and then stays at a shell, which Terminal and iTerm open in a new window or tab.
    private static func url(for item: LaunchItem) -> URL? {
        switch item {
        case .link(let text):
            return URL(string: text)
        case .path(let path):
            return URL(filePath: (path as NSString).expandingTildeInPath)
        case .command(let command):
            let script = FileManager.default.temporaryDirectory.appending(path: "spacetile-\(UUID().uuidString).command")
            let body = "#!/bin/zsh -l\nrm -f \"$0\"\ncd \"$HOME\"\n\(command)\nexec \"${SHELL:-/bin/zsh}\" -l\n"
            do {
                try body.write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                return script
            } catch {
                log.error("couldn't write the script for \(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Makes a profile's full-screen apps full screen again, one at a time, from the Desktop the
    /// window is on; macOS adds each Space after the last Desktop. A Split View pair starts with the
    /// left window and chooses the right one, as `fullscreen pair` does. Windows
    /// already full screen, or not open, are left.
    private func restoreFullScreen(_ pending: [FullScreenSnapshot], of profile: Profile, live: [SpacetileCore.WindowRef: WindowID],
                                   then done: @escaping @MainActor () -> Void) {
        guard let next = pending.first else { return done() }
        let rest = Array(pending.dropFirst())
        let ids = next.windows.compactMap { live[$0] }
        guard let first = ids.first, let window = windows[first], !FullScreen.isOn(window),
              let desktop = Spaces.space(of: first) else {
            log.notice("profile \(profile.name, privacy: .public): \(next.windows.first?.app ?? "?", privacy: .public) full screen skipped, already full screen or not open")
            return restoreFullScreen(rest, of: profile, live: live, then: done)
        }
        let partner = ids.count > 1 ? windows[ids[1]] : nil
        log.notice("profile \(profile.name, privacy: .public): \(window.appName, privacy: .public) full screen\(partner.map { " beside \($0.appName)" } ?? "", privacy: .public)")
        // The pair's picker offers the windows on the Desktop showing
        if let partner { send(partner.id, to: desktop, keepingDisplay: false) }
        Spaces.switchTo(desktop) {
            Focus.focus(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let partner, FullScreen.tile(pid: window.pid, left: true), let frame = Spaces.desktops.display(of: desktop)?.frame {
                    self.finishPair(with: partner, farHalfOf: frame, left: true)
                } else {
                    FullScreen.set(window, on: true)
                }
                // Give the Space time to form, and a pair time to be chosen, before the next
                DispatchQueue.main.asyncAfter(deadline: .now() + (partner == nil ? 1.5 : 5)) {
                    self.restoreFullScreen(rest, of: profile, live: live, then: done)
                }
            }
        }
    }

    /// Each window's ref, keyed the other way round for resolving a profile.
    /// The live window each profile reference stands for now, as applying a profile would match them.
    func liveWindows() -> [SpacetileCore.WindowRef: WindowID] { liveRefs(allWindows()) }

    private func liveRefs(_ all: [(id: WindowID, app: String, space: Spaces.ID)]) -> [SpacetileCore.WindowRef: WindowID] {
        Dictionary(SpacetileCore.WindowRef.assign(all.map { ($0.id, $0.app) }).map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Rebuilds a Space from a profile snapshot. Windows Spacetile tracks take their tiles now: it
    /// has just moved them there, so the window server needn't have caught up. The rest keep an empty
    /// tile waiting for their app, which the app's next window on this Space fills, however much
    /// later it turns up. Windows already on the Space that the profile doesn't mention stay.
    private func restore(_ snapshot: SpaceSnapshot, on space: Spaces.ID, live: [SpacetileCore.WindowRef: WindowID]) {
        let resolve = { (ref: SpacetileCore.WindowRef) in live[ref].flatMap { self.windows[$0] != nil ? $0 : nil } }
        var restored = SpaceLayout(snapshot: snapshot, resolve: resolve)
        // The profile's shape stands; windows added from here on follow the algorithms
        restored.tiling = tiling
        restored.stacking = stacking
        // The trace for profile problems: each ref placed, or waiting and why
        let trace = snapshot.windows.map { ref -> String in
            if let id = resolve(ref) { return "\(ref.app)#\(ref.index)=\(id)" }
            return "\(ref.app)#\(ref.index) waits (\(live[ref] == nil ? "not open" : "not tracked yet"))"
        }
        log.notice("restore desktop \(Spaces.number(of: space) ?? 0): \(trace.joined(separator: ", "), privacy: .public)")
        let (bounds, spacing) = tileArea(for: space)
        let existing = layouts[space]
        for id in existing?.tree.windows ?? [] where !restored.contains(id) {
            restored.add(id, app: windows[id]?.bundleID, beside: nil, in: bounds, gap: spacing.gap, minimumSizes: minimumSizes)
        }
        for id in existing?.floating ?? [] where !restored.contains(id) {
            restored.add(id, beside: nil, in: bounds, gap: spacing.gap, floating: true)
        }
        layouts[space] = restored
        apply(space)
    }

    /// After displays change or the Mac wakes: loads the profile captured on the display that's
    /// now main, if any, and otherwise lays out again, since macOS moves windows around on both.
    private func displaysSettled() {
        defer { displaysUnsettled = false }
        guard !isPaused else { return }
        let desktops = Spaces.desktops
        let display = desktops.fingerprint
        if display != lastDisplay {
            lastDisplay = display
            // Only profiles set to apply themselves, and only on exactly their displays
            if let profile = ProfileStore.all.first(where: { $0.autoApply == true && desktops.matchesExactly($0) }) {
                log.notice("displays changed to \(display, privacy: .public), applying \(profile.name, privacy: .public)")
                return load(profile)
            }
        }
        spaceChanged()
    }

    private func untrack(_ id: WindowID) {
        windows[id] = nil
        minimumSizes[id] = nil
        written[id] = nil
        beforeNativeTile[id] = nil
        movedByOthers.remove(id)
        removeFromLayouts(id)
    }

    private func removeFromLayouts(_ id: WindowID) {
        for (space, layout) in layouts where layout.contains(id) {
            layouts[space]?.remove(id)
            if lastFocusedTiled[space] == id { lastFocusedTiled[space] = nil }
            apply(space)
        }
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            AXWindow(element, pid: element.pid).map { track($0, applyingRules: true) }
        case kAXUIElementDestroyedNotification:
            // A destroyed element can't report its window number, so match the stored handle
            windows.values.first { CFEqual($0.element, element) }.map { untrack($0.id) }
        case kAXWindowMiniaturizedNotification:
            windows.values.first { CFEqual($0.element, element) }.map { window in
                // Restoring it puts it back in this tile while a neighbour is still there
                if let space = layoutSpace(of: window.id), let slot = layouts[space]?.slot(of: window.id) {
                    savedSlots[window.id] = (window.pid, space, slot)
                }
                removeFromLayouts(window.id)
            }
        case kAXWindowDeminiaturizedNotification:
            windows.values.first { CFEqual($0.element, element) }.map { layoutIfTileable($0) }
        case kAXMovedNotification, kAXResizedNotification:
            windows.values.first { CFEqual($0.element, element) }.map { movedByOther($0) }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            // The app's own main window, front or not: selecting a tab changes it. The old tab
            // leaves its Space a moment after
            if let window = AXWindow(element, pid: element.pid) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.followTabs(to: window) }
            }
            focusChanged()
        default:
            break
        }
    }

    private func spaceChanged() {
        let interval = signposter.beginInterval("Space change")
        defer { signposter.endInterval("Space change", interval) }
        let desktops = Spaces.desktops
        for display in desktops.displays where shownSpace[display.id] != display.current {
            previousSpace[display.id] = shownSpace[display.id]
            shownSpace[display.id] = display.current
        }
        let kept = settleDisplayChange(desktops)
        reconcileSpaceMembership(keeping: kept)
        for pid in Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)) {
            observe(pid, applyingRules: false)
        }
        // A window leaving full screen can still report it while the Space slides back; look again
        let leaving = fullScreenPIDs.union(savedSlots.values.map(\.pid))
        fullScreenPIDs = []
        for pid in leaving {
            for delay in [0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.observe(pid, applyingRules: false) }
            }
        }
        capturePreviewsSoon()
        // Every display shows a Space; lay each out. After displays change, every Desktop's windows
        // go back onto their own display, shown or not
        for space in desktops.visible { apply(space) }
        if !kept.isEmpty {
            for space in layouts.keys where !desktops.visible.contains(space) && desktops.display(of: space) != nil { apply(space) }
        }
        highlight.follow(focusedWindow())
        publishStatus()
    }

    /// Puts back the layouts of a display that reconnected, taking their windows from wherever they
    /// went meanwhile. Returns the windows whose layout stands while the displays settle: those
    /// restored, and every window of a display that stayed. A display coming or going moves the
    /// others' coordinates, so their windows' frames briefly sit over another display; laying them
    /// out moves them back onto their own.
    private func settleDisplayChange(_ desktops: Desktops) -> Set<WindowID> {
        defer { lastDesktops = desktops }
        // The arrangement also catches a change a Space change reports before its notification
        let arrangement = { (desktops: Desktops) in Set(desktops.displays.map { "\($0.id) \($0.frame)" }) }
        guard let old = lastDesktops, displaysUnsettled || arrangement(old) != arrangement(desktops) else { return [] }
        var kept = Set(layouts.filter { desktops.display(of: $0.key) != nil }.flatMap { $0.value.tree.windows + $0.value.floating })
        for (space, saved) in departed.update(from: old, to: desktops, layouts: layouts) {
            var layout = saved
            for id in layout.tree.windows + layout.floating where !BSPTree.isHole(id) && windows[id] == nil { layout.remove(id) }
            let members = Set(layout.tree.windows + layout.floating)
            for other in layouts.keys where other != space {
                for id in members where layouts[other]?.contains(id) == true { layouts[other]?.remove(id) }
            }
            layouts[space] = layout
            kept.formUnion(members)
            log.notice("display back: restored desktop \(Spaces.number(of: space) ?? 0) with \(members.count) window(s)")
        }
        return kept
    }

    /// Windows dragged between Spaces in Mission Control keep their old layout membership until
    /// this moves them to the layout of the Space they're really on, except `kept` ones.
    private func reconcileSpaceMembership(keeping kept: Set<WindowID> = []) {
        // With Spaces spanning displays, which display a window is on comes from its bounds: read
        // them all at once rather than per window
        let desktops = Spaces.desktops
        let bounds = desktops.spansDisplays ? Self.windowBounds() : [:]
        for (space, layout) in layouts {
            for id in layout.tree.windows + layout.floating where !kept.contains(id) {
                guard let actual = Spaces.space(of: id, bounds: bounds[id]), actual != space else { continue }
                // Onto another display in the same shared Space: only once it's at least half there,
                // so a stale position just after Spacetile moved it can't pull it back
                if desktops.real(actual) == desktops.real(space), let frame = bounds[id], let display = desktops.display(of: actual),
                   Spaces.overlap(display.frame, frame) < frame.width * frame.height / 2 { continue }
                // Native full screen gives a window an unnumbered Space of its own. Stop tiling it, but
                // keep its slot: leaving full screen changes Space, which tracks it again and puts it back
                guard Spaces.number(of: actual) != nil else {
                    log.notice("window \(id) went full screen, no longer tiled")
                    if let pid = windows[id]?.pid, let slot = layout.slot(of: id) { savedSlots[id] = (pid, space, slot) }
                    untrack(id)
                    continue
                }
                log.notice("window \(id) moved outside Spacetile to space \(Spaces.number(of: actual) ?? 0)")
                relocate(id, from: space, to: actual)
            }
        }
    }

    private func focusChanged() {
        // Any focus change can move the active display, tiled window or not
        defer { refreshStatus() }
        emptyDisplay = nil
        let focused = focusedWindow()
        highlight.follow(focused)
        guard let focused else { return }
        let space = Spaces.space(of: focused.id) ?? Spaces.active
        guard layouts[space]?.tree.contains(focused.id) == true else { return }
        lastFocusedTiled[space] = focused.id
        layouts[space]?.focus(focused.id)
        // An accordion fans out round the window in front
        if let layout = layouts[space], layout.mode == .stack, layout.stacking == .accordion { apply(space) }
    }

    /// Native window tabs share one frame, and only the selected tab is on a Space. A laid-out window
    /// of the focused app that has left every Space without being minimised or hidden is a tab
    /// switched away from or merged into a group. The focused window takes the first such tile and
    /// any others close.
    private func followTabs(to focused: AXWindow) {
        var replaced = false
        for (space, layout) in layouts {
            let away = (layout.tree.windows + layout.floating).filter {
                $0 != focused.id && windows[$0]?.pid == focused.pid && Spaces.space(of: $0) == nil
            }
            // A tab Spacetile hasn't seen (it only lists the selected one) joins in the old tab's place
            guard !away.isEmpty, windows[focused.id] != nil || register(focused) else { continue }
            for id in away {
                if replaced {
                    layouts[space]?.remove(id)
                } else {
                    for other in layouts.keys where other != space && layouts[other]?.contains(focused.id) == true {
                        layouts[other]?.remove(focused.id)
                        apply(other)
                    }
                    log.notice("window \(focused.id) is the selected tab now, in \(id)'s place")
                    layouts[space]?.replace(id, with: focused.id)
                    replaced = true
                }
                if lastFocusedTiled[space] == id { lastFocusedTiled[space] = nil }
            }
            apply(space)
        }
    }

    /// Redraws the menu-bar item for whichever display is active now, and again shortly after:
    /// macOS moves the active menu bar a moment after the focus change that causes it.
    func refreshStatus() {
        publishStatus()
        statusRecheck?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.publishStatus() } }
        statusRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func publishStatus() {
        // The menu-bar item describes the active display, the one with the menu bar
        let desktops = Spaces.desktops
        let current = desktops.activeSpace ?? 0, order = desktops.active?.order ?? []
        // The menu bar numbers by position; the label and default mode belong to the Desktop
        let number = desktops.number(of: current)
        if Date().timeIntervalSince(occupancy.at) > 0.5 {
            let used = Set(allWindows().map(\.space))
            occupancy = (order.map(used.contains), Date())
        }
        let layout = layouts[current]
        status = Status(space: desktops.position(of: current), label: number.flatMap { spaceRules.labels[$0] },
                        stacked: layout?.stackedOutOfSight ?? 0, total: order.count,
                        mode: layout?.mode ?? spaceRules.layout(forSpace: number),
                        windowCount: (layout?.tree.windows.count ?? 0) + (layout?.floating.count ?? 0),
                        floating: layout?.floating.count ?? 0, paused: isPaused,
                        displays: desktops.displays.map { DisplayIndex(number: desktops.position(of: $0.current), isActive: $0.id == desktops.active?.id) },
                        isFullScreen: desktops.isFullScreen(current),
                        order: order.enumerated().map { index, space in
                            desktops.isFullScreen(space) ? .fullScreen
                                : .desktop(occupied: occupancy.spaces.indices.contains(index) && occupancy.spaces[index])
                        },
                        profile: lastProfile, profileIcon: lastProfile == nil ? nil : lastProfileIcon)
        onStatusChange(status)
    }

    // MARK: - Applying layouts

    /// A Space's layout, created with its Space's default mode on first use.
    private func layout(for space: Spaces.ID) -> SpaceLayout {
        layouts[space] ?? SpaceLayout(mode: spaceRules.layout(forSpace: Spaces.number(of: space)), tiling: tiling, stacking: stacking)
    }

    /// Writes every tiled window's frame, then reads frames back. A window that stayed larger than
    /// its tile reveals its minimum size; the layout is then re-normalised (stacking it) and rewritten.
    /// `learning` is off during a live drag so a neighbour can't stack mid-gesture.
    private func apply(_ space: Spaces.ID, skipping skipped: WindowID? = nil, learning: Bool = true) {
        if isPaused, space == Spaces.active { publishStatus() }
        guard !isPaused, layouts[space] != nil else { return }
        let interval = signposter.beginInterval("Layout")
        defer { signposter.endInterval("Layout", interval) }
        let (bounds, spacing) = tileArea(for: space)
        // Only the first pass animates: later ones fix windows that turned out to have a minimum
        // size, and a live drag or a hidden Space wants its frames at once
        var animated = animatesWindows && learning && Spaces.desktops.visible.contains(space)
        for _ in 0..<3 {
            layouts[space]?.normalize(in: bounds, gap: spacing.gap, minimumSizes: minimumSizes)
            var frames = layouts[space]!.frames(in: bounds, gap: spacing.gap)
            frames[skipped ?? 0] = nil
            write(frames, animated: animated)
            animated = false
            guard learning, learnMinimumSizes(from: frames, within: bounds) else { break }
        }
        // One preselect hint at a time, for the display with the menu bar
        if space == Spaces.active {
            publishStatus()
            // The preselect hint stays up until a window takes the spot or it's cancelled
            if let rect = layouts[space]?.preselectionRect(in: bounds, gap: spacing.gap) {
                preselectOverlay.show(rect, as: .preselect)
            } else {
                preselectOverlay.hide()
            }
        }
    }

    private func write(_ frames: [WindowID: CGRect], animated: Bool = false) {
        let pids = Set(frames.keys.compactMap { windows[$0]?.pid })
        // Apps with AXEnhancedUserInterface on (set by assistive tools) animate every frame change
        let enhanced = pids.filter { AXUIElementCreateApplication($0).value(of: "AXEnhancedUserInterface") == true }
        for pid in enhanced { setEnhancedUI(false, pid) }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animate(to: frames) }
        let now = Date()
        for (id, frame) in frames {
            windows[id]?.setFrame(frame)
            written[id] = (frame, now)
        }
        for pid in enhanced { setEnhancedUI(true, pid) }
    }

    /// Steps each window that moves towards its frame for `FrameAnimation.duration`; `write` then
    /// sets the final frames. It holds the main thread, since the layout reads frames back as soon as
    /// they're written. A step takes as long as its Accessibility writes, so a slow app gets fewer
    /// steps, not a longer animation.
    private func animate(to frames: [WindowID: CGRect]) {
        let start = Dictionary(frames.keys.compactMap { id in windows[id]?.frame.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
        let animation = FrameAnimation(from: start, to: frames)
        guard !animation.isEmpty else { return }
        let interval = signposter.beginInterval("Animate")
        defer { signposter.endInterval("Animate", interval) }
        let begin = Date()
        while true {
            let progress = Date().timeIntervalSince(begin) / FrameAnimation.duration
            guard progress < 1 else { break }
            for (id, frame) in animation.frames(at: progress) { windows[id]?.step(to: frame) }
            Thread.sleep(forTimeInterval: 1.0 / 120)
        }
    }

    /// Returns whether any window revealed a minimum size larger than what was known.
    private func learnMinimumSizes(from targets: [WindowID: CGRect], within area: CGRect) -> Bool {
        var learned = false
        for (id, target) in targets {
            // A full-screen window reads back as the whole display, which is no minimum: learning it
            // would stack every other window on the Space for good
            guard let window = windows[id], let actual = window.frame, window.element.value(of: "AXFullScreen") != true,
                  actual.width <= area.width + 1, actual.height <= area.height + 1 else { continue }
            let known = minimumSizes[id] ?? .zero
            let width = actual.width > target.width + 1 ? actual.width : known.width
            let height = actual.height > target.height + 1 ? actual.height : known.height
            guard width > known.width || height > known.height else { continue }
            minimumSizes[id] = CGSize(width: width, height: height)
            log.notice("window \(id) minimum size \(Int(width))x\(Int(height))")
            learned = true
        }
        return learned
    }

    private func setEnhancedUI(_ on: Bool, _ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, on as CFBoolean)
    }

    /// The visible frame of the display showing `space`, in AX coordinates (top-left origin), inset by padding.
    private func tileArea(for space: Spaces.ID) -> (bounds: CGRect, spacing: Spacing) {
        let screen = Spaces.screen(of: space) ?? NSScreen.screens[0]
        let spacing = spacingSettings.spacing(forDisplayWidth: screen.frame.width)
        return (visibleArea(for: space).insetBy(dx: spacing.padding, dy: spacing.padding), spacing)
    }

    /// The visible frame of the display showing `space` (below the menu bar, beside the Dock), in AX
    /// coordinates: what macOS's own tiling divides up.
    private func visibleArea(for space: Spaces.ID) -> CGRect {
        let screen = Spaces.screen(of: space) ?? NSScreen.screens[0]
        let primaryHeight = NSScreen.screens[0].frame.height
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
    }

    // MARK: - macOS tiling

    /// Something other than Spacetile moved or resized a managed window: maybe macOS's own tiling
    /// (the green button, the Window menu, fn⌃ arrows). Mouse drags are Mouse's, and Spacetile's own
    /// writes come back as moves too; both are ignored. The rest wait until the moves stop, since
    /// Fill & Arrange moves several windows one after another, then are read together.
    private func movedByOther(_ window: AXWindow) {
        guard adoptsNativeTiling, !isPaused, !displaysUnsettled, NSEvent.pressedMouseButtons == 0,
              layoutSpace(of: window.id) != nil, let frame = window.frame, !FullScreen.isOn(window) else { return }
        if let last = written[window.id], Self.close(last.frame, frame, within: 2) { return }
        movedByOthers.insert(window.id)
        nativeSettle?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.settleMovedWindows() } }
        nativeSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Pictures of the windows now showing, half a second after the Space changes so they've been
    /// drawn, for the mini-map's cards. Only windows on screen can be captured, so this is how a
    /// full-screen app, whose Space hides the menu bar, gets a picture at all.
    private func capturePreviewsSoon() {
        guard WindowPreviews.shared.enabled else { return }
        previewCapture?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated {
            let all = self.allWindowsWithBounds(fullScreen: true)
            let visible = Set(Spaces.desktops.visible)
            WindowPreviews.shared.keep(only: Set(all.map(\.id)))
            WindowPreviews.shared.refresh(all.filter { visible.contains($0.space) }.map(\.id))
        } }
        previewCapture = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// On resume: each showing Space whose tiled windows were arranged into a clean tiling while
    /// paused (by macOS or by hand) keeps that arrangement, rather than going back to the old tree.
    private func adoptOnScreen() {
        guard adoptsNativeTiling else { return }
        reconcileSpaceMembership()
        for space in Spaces.desktops.visible {
            guard var layout = layouts[space], layout.mode == .bsp else { continue }
            let frames = Dictionary(layout.tree.windows.compactMap { id in windows[id]?.frame.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
            guard frames.count > 1, NativeTiling.covers(Array(frames.values), visibleArea(for: space)),
                  let arranged = NativeTiling.tree(from: frames) else { continue }
            let before = layout.tree
            layout.adopt(arranged)
            guard layout.tree != before else { continue }
            log.notice("resumed: keeping the arrangement on desktop \(Spaces.number(of: space) ?? 0)")
            let (bounds, spacing) = tileArea(for: space)
            layout.normalize(in: bounds, gap: spacing.gap, minimumSizes: minimumSizes)
            layouts[space] = layout
        }
    }

    private func settleMovedWindows() {
        let moved = movedByOthers
        movedByOthers = []
        guard !isPaused, NSEvent.pressedMouseButtons == 0 else { return }
        var bySpace: [Spaces.ID: [WindowID]] = [:]
        for id in moved { layoutSpace(of: id).map { bySpace[$0, default: []].append(id) } }
        for (space, ids) in bySpace { readNativeTiling(ids.sorted(), on: space) }
    }

    /// Turns what macOS tiling did into the matching Spacetile change, so the window stays where it
    /// was put and the others re-tile round it: a half or quarter is `place`, Fill is zoom, and an
    /// arrangement of several windows becomes that tree. Return to Previous Size restores. Any other
    /// move of a tiled window is put back, as before.
    private func readNativeTiling(_ ids: [WindowID], on space: Spaces.ID) {
        guard var layout = layouts[space] else { return }
        let frames = Dictionary(ids.compactMap { id in windows[id]?.frame.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
        // Just after Spacetile wrote it, a frame that isn't a tile is the app settling (a minimum
        // size, an animation), not something to put back
        let recent = ids.contains { Date().timeIntervalSince(written[$0]?.at ?? .distantPast) < 0.5 }
        guard layout.mode == .bsp else {
            // Stack Spaces keep every window full size; float Spaces leave windows where they are
            if layout.mode == .stack, !recent { apply(space) }
            return
        }
        let visible = visibleArea(for: space)
        let (bounds, spacing) = tileArea(for: space)
        let tiles = layout.frames(in: bounds, gap: spacing.gap)
        let desktop = Spaces.number(of: space) ?? 0
        // Several windows at once that cut cleanly into tiles: Fill & Arrange over the display, or
        // windows tiled together into one half of it
        if frames.count > 1, let arranged = NativeTiling.tree(from: frames) {
            let area = frames.values.reduce(CGRect.null) { $0.union($1) }
            var half: Direction?
            if case .region(.edge(let edge, _))? = NativeTiling.classify(area, in: visible) { half = edge }
            if NativeTiling.covers(Array(frames.values), visible) || half != nil {
                log.notice("macOS arranged \(frames.count) windows on desktop \(desktop)\(half.map { " in the \($0) half" } ?? "", privacy: .public): adopting it")
                for id in frames.keys { tiles[id].map { beforeNativeTile[id] = $0 } }
                if let half { layout.adopt(arranged, inHalf: half) } else { layout.adopt(arranged) }
                layout.normalize(in: bounds, gap: spacing.gap, minimumSizes: minimumSizes)
                layouts[space] = layout
                return apply(space)
            }
        }
        var changed = false
        // Floating windows keep whatever frame macOS gave them
        for (id, frame) in frames.sorted(by: { $0.key < $1.key }) where layout.tree.contains(id) {
            switch NativeTiling.classify(frame, in: visible) {
            case .region(let region)?:
                log.notice("macOS tiled \(id) on desktop \(desktop): place \(region.text, privacy: .public)")
                beforeNativeTile[id] = tiles[id]
                layout.place(id, in: region, bounds: bounds)
            case .fill?:
                log.notice("macOS filled the display with \(id) on desktop \(desktop): zoom")
                beforeNativeTile[id] = tiles[id]
                layout.zoom(id)
            case nil:
                if let before = beforeNativeTile.removeValue(forKey: id), Self.close(before, frame, within: 6) {
                    // Return to Previous Size: back to the tile it had before macOS tiled it
                    log.notice("\(id) returned to its previous size on desktop \(desktop): restore")
                    if layout.zoomed == id { layout.toggleZoom(id) } else { layout.restore(in: bounds) }
                } else if recent {
                    continue
                } else {
                    log.notice("\(id) moved on desktop \(desktop), not to a tile: putting it back")
                }
            }
            changed = true
        }
        if changed {
            layouts[space] = layout
            apply(space)
        }
    }

    private static func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// The focused window of the frontmost app, as the window server sees it. Accessibility's
    /// system-wide focus lags or reads empty after a focus-without-raise, so it isn't used.
    private func focusedWindow() -> AXWindow? {
        guard let pid = Focus.frontmostPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let window: AXUIElement? = app.value(of: kAXFocusedWindowAttribute) ?? app.value(of: kAXMainWindowAttribute)
        return window.flatMap { AXWindow($0, pid: pid) }
    }

    /// Mouse follows focus: the cursor jumps to the window's centre unless it's already inside.
    private func moveMouse(into window: AXWindow) {
        guard mouseFollowsFocus, let frame = window.frame,
              let cursor = CGEvent(source: nil)?.location, !frame.contains(cursor) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }
}

// A C function pointer, so it can't carry the target's default main-actor isolation
nonisolated private func axCallback(_: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // Observers are added to the main run loop, so this callback always runs on the main thread
    nonisolated(unsafe) let element = element
    MainActor.assumeIsolated { manager.handle(name, element: element) }
}

extension AXUIElement {
    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }
}
