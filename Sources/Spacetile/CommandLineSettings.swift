import AppKit
import SpacetileInstall
import SwiftUI

/// Installation is independent of config.json, Restore Defaults and Settings undo.
struct CommandLineSettings: View {
    @Environment(\.openURL) private var openURL
    @State private var status: CommandLineLink.Status = .missing
    @State private var installing = false
    @State private var message: String?

    private var link: CommandLineLink? {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let applications = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        guard bundle.pathExtension == "app", applications.contains(where: { bundle.path.hasPrefix($0) }),
              let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return CommandLineLink(executable: executable.path)
    }

    var body: some View {
        Section {
            LabeledContent {
                Button(status == .installed ? "Installed" : "Install Command…", action: install)
                    .disabled(installing || status != .missing || link == nil)
            } label: {
                Text("spacetile").font(.body.monospaced())
                Text("Load profiles and control windows from your terminal or automation.")
            }
            if status == .installed {
                Label("Installed at \(CommandLineLink.installedPath)", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if status == .conflict {
                Text("\(CommandLineLink.installedPath) already exists and points elsewhere. Move or remove it yourself before installing; Spacetile will leave it unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if link == nil {
                Text("Move Spacetile to Applications and open it there before installing the command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            Button("Command-line guide") {
                openURL(URL(string: "https://spacetile.app/docs/commands/#installed-app")!)
            }
        } header: {
            Text("Command line")
        } footer: {
            Text("Creates /usr/local/bin/spacetile pointing to this app. macOS may ask for an administrator password. Keep Spacetile running when sending commands.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() { status = link?.status ?? .missing }

    private func install() {
        guard let link else { return }
        installing = true
        message = nil
        defer { installing = false; refresh() }
        do {
            try link.install()
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
            // The standard macOS authentication dialog handles the password; the app never sees it.
            var failure: NSDictionary?
            guard let script = NSAppleScript(source: link.installAppleScript) else {
                message = "Could not prepare the installer. Try again."
                return
            }
            script.executeAndReturnError(&failure)
            if let failure {
                // Cancelling authentication makes no change and needs no error banner.
                if (failure[NSAppleScript.errorNumber] as? NSNumber)?.intValue != -128 {
                    message = failure[NSAppleScript.errorMessage] as? String ?? "Could not install the command. Try again."
                }
                return
            }
        } catch {
            message = "Could not install the command: \(error.localizedDescription)"
            return
        }
        if link.status != .installed {
            message = "The command could not be verified. Check /usr/local/bin/spacetile and try again."
        }
    }
}
