// Prints what the window server and an app's Window menu say about native full screen, Split
// View and window tiling. Run through `scripts/fullscreen-probe`, which
// links SkyLight. Set up the case first (an app full screen, two apps in Split View, a window
// tiled from the green button), then run it. `--menu <App>` also dumps that app's Window menu,
// which needs Accessibility for the terminal.
import AppKit

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("SLSGetActiveSpace") func SLSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("SLSCopySpacesForWindows") func SLSCopySpacesForWindows(_ cid: Int32, _ selector: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

let cid = SLSMainConnectionID()
let arguments = CommandLine.arguments.dropFirst()

/// A dictionary with nested dictionaries and arrays, one key per line, keys sorted.
func dump(_ value: Any, indent: String) {
    if let dictionary = value as? [String: Any] {
        for key in dictionary.keys.sorted() {
            let child = dictionary[key]!
            if child is [String: Any] || child is [Any] {
                print("\(indent)\(key):")
                dump(child, indent: indent + "  ")
            } else {
                print("\(indent)\(key): \(child)")
            }
        }
    } else if let array = value as? [Any] {
        for (index, child) in array.enumerated() {
            print("\(indent)[\(index)]")
            dump(child, indent: indent + "  ")
        }
    } else {
        print("\(indent)\(value)")
    }
}

// MARK: - Settings that change how native tiling and Spaces behave

print("== Settings")
for (domain, keys) in [
    ("com.apple.WindowManager", ["GloballyEnabled", "EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag",
                                "EnableTilingOptionAccelerator", "EnableTiledWindowMargins"]),
    ("com.apple.dock", ["mru-spaces"]),
    ("com.apple.spaces", ["spans-displays"]),
] {
    for key in keys {
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        print("\(domain) \(key) = \(value.map { "\($0)" } ?? "unset (default)")")
    }
}
print("Active Space:", SLSGetActiveSpace(cid))

// MARK: - Screens, for working out native tile geometry

print("\n== Screens (AppKit, bottom-left origin)")
for screen in NSScreen.screens {
    print("\(screen.localizedName): frame \(screen.frame), visible \(screen.visibleFrame)")
}

// MARK: - Every Space, in Mission Control order, with full detail for anything not a Desktop

print("\n== Spaces")
var spaceTypes: [Int: Int] = [:]
for entry in SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? [] {
    print("Display \(entry["Display Identifier"] ?? "?")")
    print("  current: \((entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] ?? "?")")
    for space in entry["Spaces"] as? [[String: Any]] ?? [] {
        let id = space["ManagedSpaceID"] as? Int ?? 0, type = space["type"] as? Int ?? -1
        spaceTypes[id] = type
        print("  space \(id) type \(type)\(type == 0 ? " (Desktop)" : "")")
        // Desktops are known; full-screen Spaces are what this probe is for
        if type != 0 { dump(space, indent: "    ") }
    }
}

// MARK: - Windows on Spaces that aren't Desktops

print("\n== Windows on non-Desktop Spaces (layer 0)")
let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in info where window[kCGWindowLayer as String] as? Int == 0 {
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    let spaces = SLSCopySpacesForWindows(cid, 0x7, [number] as CFArray)?.takeRetainedValue() as? [Int] ?? []
    guard spaces.contains(where: { (spaceTypes[$0] ?? 0) != 0 }) else { continue }
    let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
    print("window \(number) \(window[kCGWindowOwnerName as String] ?? "?") pid \(window[kCGWindowOwnerPID as String] ?? "?")"
        + " spaces \(spaces) bounds \(bounds) onscreen \(window[kCGWindowIsOnscreen as String] ?? false)")
}

// MARK: - An app's Window menu: Move & Resize, Fill & Arrange, Full Screen Tile

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) ?? [] }

/// Menu items with their identifiers and shortcuts, recursing into submenus.
func dumpMenu(_ menu: AXUIElement, indent: String) {
    for item in children(menu) {
        let title: String = attribute(item, kAXTitleAttribute) ?? ""
        let identifier: String = attribute(item, kAXIdentifierAttribute) ?? "-"
        let key: String = attribute(item, kAXMenuItemCmdCharAttribute) ?? ""
        let modifiers: Int = attribute(item, kAXMenuItemCmdModifiersAttribute) ?? 0
        let enabled: Bool = attribute(item, kAXEnabledAttribute) ?? false
        if !title.isEmpty {
            print("\(indent)\(title)  [id \(identifier)] [key \(key.isEmpty ? "-" : "\(key) mods \(modifiers)")]\(enabled ? "" : " (disabled)")")
        }
        for submenu in children(item) { dumpMenu(submenu, indent: indent + "  ") }
    }
}

if let flag = arguments.firstIndex(of: "--menu") {
    let name = arguments[(flag + 1)...].joined(separator: " ")
    print("\n== Window menu of \(name)")
    if !AXIsProcessTrusted() {
        print("Needs Accessibility for this terminal (System Settings ▸ Privacy & Security ▸ Accessibility)")
    } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if let menuBar: AXUIElement = attribute(element, kAXMenuBarAttribute) {
            // The Window menu is second to last before Help in nearly every app; print it and any
            // menu whose title says Window, so a localised system still shows something
            let items = children(menuBar)
            let titled = items.filter { (attribute($0, kAXTitleAttribute) as String?) == "Window" }
            let fallback = items.count >= 2 ? [items[items.count - 2]] : []
            for item in titled.isEmpty ? fallback : titled {
                let title: String = attribute(item, kAXTitleAttribute) ?? "?"
                print(title)
                for menu in children(item) { dumpMenu(menu, indent: "  ") }
            }
        }
        if let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute) {
            let fullScreen: Bool = attribute(window, "AXFullScreen") ?? false
            let names: [String] = {
                var names: CFArray?
                AXUIElementCopyAttributeNames(window, &names)
                return names as? [String] ?? []
            }()
            print("\nFocused window: AXFullScreen \(fullScreen)")
            print("Attributes: \(names.sorted().joined(separator: ", "))")
        }
    } else {
        print("No running app named \(name)")
    }
}
