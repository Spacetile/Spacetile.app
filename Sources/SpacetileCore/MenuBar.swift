/// What the menu-bar item shows, in order, and how the Space index is drawn.
public struct MenuBarSettings: Codable, Equatable, Sendable {
    public var items: [Entry]
    public var indexStyle: IndexStyle

    public struct Entry: Codable, Equatable, Sendable {
        public var item: Item
        public var shown: Bool

        public init(_ item: Item, shown: Bool) {
            self.item = item
            self.shown = shown
        }
    }

    public enum Item: String, Codable, CaseIterable, Sendable {
        case logo, index, name, layout, windowCount, stacked
        /// The icon and the name of the profile applied, or saved from the mini-map, last.
        case profileIcon, profileName
    }

    public enum IndexStyle: String, Codable, CaseIterable, Sendable {
        /// One square per Space, the current one filled.
        case stepper
        /// The current number in a single square.
        case single
        /// The current number on every display, the active one bright. Every display's menu bar
        /// shows the same item, so this keeps each display's Space in view wherever you look.
        case displays
    }

    public init(items: [Entry], indexStyle: IndexStyle) {
        self.items = items
        self.indexStyle = indexStyle
    }

    /// Close to the original title, "3 code +2". The profile items lead, hidden; settings saved before
    /// they existed get them last, also hidden.
    public static let `default` = MenuBarSettings(
        items: [.init(.profileIcon, shown: false), .init(.profileName, shown: false),
                .init(.logo, shown: false), .init(.index, shown: true), .init(.name, shown: true),
                .init(.layout, shown: false), .init(.windowCount, shown: false), .init(.stacked, shown: true)],
        indexStyle: .single
    )

    /// Items in order, with any the file doesn't mention added hidden at the end, so older
    /// configs and hand edits stay valid as items are added.
    public var orderedItems: [Entry] {
        let listed = Set(items.map(\.item))
        return items + Item.allCases.filter { !listed.contains($0) }.map { Entry($0, shown: false) }
    }
}
