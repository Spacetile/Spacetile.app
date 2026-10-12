import ApplicationServices
import SpacetileCore

/// What tiling waits for before it starts: Accessibility, then the EULA. The Welcome guide asks for both.
enum TilingPrerequisite {
    case accessibility, eula

    /// The first one still missing, or nil when Spacetile is ready to tile.
    static var missing: TilingPrerequisite? {
        if !AXIsProcessTrusted() { return .accessibility }
        return EULA.isAccepted() ? nil : .eula
    }

    var waiting: String {
        switch self {
        case .accessibility: "Spacetile needs Accessibility permission"
        case .eula: "Spacetile needs you to agree to its EULA"
        }
    }

    /// The menu item that opens the Welcome guide to see to it.
    var setUp: String {
        switch self {
        case .accessibility: "Set Up Accessibility…"
        case .eula: "Show Welcome Guide…"
        }
    }
}
