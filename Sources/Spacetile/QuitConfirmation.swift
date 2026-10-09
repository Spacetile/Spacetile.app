import AppKit
import SpacetileCore

/// Quitting apps loses work if they don't save, so a profile's first quit asks, and "Don't ask
/// again" is remembered per profile.
enum QuitConfirmation {
    static func confirm(_ apps: [NSRunningApplication], for profile: Profile) -> Bool {
        let key = "quitUnlistedConfirmed.\(profile.name)"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let alert = NSAlert()
        alert.messageText = "Quit apps not in “\(profile.name)”?"
        alert.informativeText = apps.compactMap(\.localizedName).sorted().joined(separator: ", ")
            + "\n\nApps with unsaved changes will ask before quitting."
        alert.addButton(withTitle: "Quit Apps")
        alert.addButton(withTitle: "Skip")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again for this profile"
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: key) }
        return confirmed
    }
}
