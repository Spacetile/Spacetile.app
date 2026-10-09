/// One action as Settings → Keys lists it. `spacetile-catalog` exports the same list for the
/// Raycast extension, so both offer the same commands.
public struct KeyAction: Identifiable, Sendable {
    public let command: String
    public let title: String
    public let picture: Picture
    public var id: String { command }

    public enum Picture: Sendable {
        case symbol(String)
        case region(Region)
    }

    static func symbol(_ command: String, _ title: String, _ name: String) -> KeyAction {
        KeyAction(command: command, title: title, picture: .symbol(name))
    }

    static func place(_ text: String, _ title: String) -> KeyAction {
        KeyAction(command: "place \(text)", title: title, picture: .region(Region(text)!))
    }

    /// Grouped by modifier family, so each section has one prefix that its picker changes.
    public static let sections: [(title: String, symbol: String, actions: [KeyAction])] = [
        ("Focus", "scope", [
            .symbol("focus west", "Focus the window on the left", "arrow.left"),
            .symbol("focus south", "Focus the window below", "arrow.down"),
            .symbol("focus north", "Focus the window above", "arrow.up"),
            .symbol("focus east", "Focus the window on the right", "arrow.right"),
            .symbol("space prev", "Previous Space", "chevron.left.2"),
            .symbol("space next", "Next Space", "chevron.right.2"),
            .symbol("space last", "Last-used Space", "arrow.uturn.backward"),
            .symbol("display next", "Focus next display", "display"),
            .symbol("display prev", "Focus previous display", "display"),
            .symbol("stack prev", "Previous window in stack", "square.stack"),
            .symbol("stack next", "Next window in stack", "square.stack.fill"),
        ]),
        ("Move", "arrow.up.and.down.and.arrow.left.and.right", [
            .symbol("swap west", "Swap with the window on the left", "arrow.left.square"),
            .symbol("swap south", "Swap with the window below", "arrow.down.square"),
            .symbol("swap north", "Swap with the window above", "arrow.up.square"),
            .symbol("swap east", "Swap with the window on the right", "arrow.right.square"),
            .symbol("pop out", "Pop out", "arrow.up.left.square"),
            .symbol("pop in", "Pop back in", "arrow.down.right.square"),
            .symbol("send prev", "Send to previous Space", "rectangle.portrait.and.arrow.forward"),
            .symbol("send next", "Send to next Space", "rectangle.portrait.and.arrow.right"),
            .symbol("send display next", "Send to next display", "macwindow.badge.plus"),
            .symbol("send display prev", "Send to previous display", "macwindow.badge.plus"),
        ]),
        ("Join", "arrow.uturn.right.square", [
            .symbol("join west", "Join with the window on the left", "arrow.uturn.left.square"),
            .symbol("join south", "Join with the window below", "arrow.uturn.down.square"),
            .symbol("join north", "Join with the window above", "arrow.uturn.up.square"),
            .symbol("join east", "Join with the window on the right", "arrow.uturn.right.square"),
        ]),
        ("Layout", "rectangle.split.2x2", [
            .symbol("zoom", "Zoom (fill the Space)", "arrow.up.left.and.arrow.down.right"),
            .symbol("float", "Toggle float", "macwindow.on.rectangle"),
            .symbol("split", "Toggle split direction", "rectangle.split.1x2"),
            .symbol("balance", "Balance", "equal.square"),
            .symbol("layout bsp", "Tile this Space", LayoutMode.bsp.symbol),
            .symbol("layout stack", "Stack this Space", LayoutMode.stack.symbol),
            .symbol("layout float", "Float this Space", LayoutMode.float.symbol),
            .symbol("mirror horizontal", "Mirror left ↔ right", "arrow.left.and.right.righttriangle.left.righttriangle.right"),
            .symbol("mirror vertical", "Mirror top ↕ bottom", "arrow.up.and.down.righttriangle.up.righttriangle.down"),
            .symbol("rotate 90", "Rotate clockwise", "rotate.right"),
            .symbol("rotate 270", "Rotate anticlockwise", "rotate.left"),
            .symbol("retile", "Retile", "arrow.clockwise"),
            .symbol("close", "Close window", "xmark.square"),
        ]),
        ("Place & Size", "rectangle.split.3x3", [
            .symbol("place column", "Maximize height", "arrow.up.and.down.square"),
            .place("left", "Left ½ → ⅔ → ⅓"),
            .place("right", "Right ½ → ⅔ → ⅓"),
            .place("top", "Top ½ → ⅔ → ⅓"),
            .place("bottom", "Bottom ½ → ⅔ → ⅓"),
            .place("left 3/4", "Left ¾"),
            .place("right 3/4", "Right ¾"),
            .place("center", "Centre ⅓"),
            .place("top-left", "Top-left ¼"),
            .place("top-right", "Top-right ¼"),
            .place("bottom-left", "Bottom-left ¼"),
            .place("bottom-right", "Bottom-right ¼"),
            .place("top-left-sixth", "Top-left ⅙"),
            .place("top-center-sixth", "Top-centre ⅙"),
            .place("top-right-sixth", "Top-right ⅙"),
            .place("bottom-left-sixth", "Bottom-left ⅙"),
            .place("bottom-center-sixth", "Bottom-centre ⅙"),
            .place("bottom-right-sixth", "Bottom-right ⅙"),
            .symbol("grow", "Grow", "arrow.up.left.and.arrow.down.right.square"),
            .symbol("shrink", "Shrink", "arrow.down.right.and.arrow.up.left.square"),
            .symbol("restore", "Restore", "arrow.uturn.backward.square"),
            .symbol("border horizontal -100", "Move vertical border left", "arrow.left.to.line"),
            .symbol("border horizontal 100", "Move vertical border right", "arrow.right.to.line"),
            .symbol("border vertical -100", "Raise horizontal border", "arrow.up.to.line"),
            .symbol("border vertical 100", "Lower horizontal border", "arrow.down.to.line"),
        ]),
        ("Full Screen", "rectangle.inset.filled", [
            .symbol("fullscreen", "Toggle full screen", "arrow.up.backward.and.arrow.down.forward"),
            .symbol("fullscreen pair", "Full screen with the neighbouring window", "rectangle.split.2x1.fill"),
            .symbol("space fullscreen prev", "Previous full-screen app", "arrow.left.square.fill"),
            .symbol("space fullscreen next", "Next full-screen app", "arrow.right.square.fill"),
        ]),
        ("Spacetile", "square.grid.2x2", [
            .symbol("pause", "Pause or resume tiling", "pause.circle"),
            .symbol("settings", "Open Settings", "gearshape"),
            .symbol("toggle spacing", "Toggle spacing", "rectangle.grid.2x2"),
            .symbol("toggle border", "Toggle active border", "square.dashed"),
            .symbol("toggle dim", "Toggle dimming", "circle.lefthalf.filled"),
        ]),
        ("Preselect", "rectangle.dashed", [
            .symbol("preselect west", "Next window goes left", "rectangle.lefthalf.inset.filled.arrow.left"),
            .symbol("preselect south", "Next window goes below", "rectangle.bottomhalf.inset.filled"),
            .symbol("preselect north", "Next window goes above", "rectangle.tophalf.inset.filled"),
            .symbol("preselect east", "Next window goes right", "rectangle.righthalf.inset.filled.arrow.right"),
        ]),
    ]

    /// An action's name as the Keys pane shows it, or the command itself if it isn't listed.
    public static func title(for command: String) -> String {
        if let action = sections.flatMap(\.actions).first(where: { $0.command == command }) { return action.title }
        let words = command.split(separator: " ")
        if words.count == 2, let number = Int(words[1]) {
            if words[0] == "space" { return "Switch to Space \(number)" }
            if words[0] == "send" { return "Send to Space \(number)" }
        }
        return command
    }

    public static var listedCommands: Set<String> {
        Set(sections.flatMap { $0.actions.map(\.command) } + (1...10).flatMap { ["space \($0)", "send \($0)"] })
    }
}
