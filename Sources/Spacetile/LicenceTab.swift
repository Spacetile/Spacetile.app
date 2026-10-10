import SpacetileCore
import SwiftUI

/// Settings → Licence: the Trial's days left or the Licence's email and update window end, and a
/// field to paste a Licence key into. The key goes to the Keychain.
struct LicenceTab: View {
    var licence: Licence
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section("Licence") {
                switch licence.state {
                case .trial(let daysLeft):
                    LabeledContent("Trial", value: "\(daysLeft) day\(daysLeft == 1 ? "" : "s") left")
                case .licensed(let licenceKey):
                    LabeledContent("Licensed to", value: licenceKey.email)
                    LabeledContent("Update window ends", value: Licence.day(licenceKey.updateWindowEnd))
                // Builds without the gate never stop, so they say nothing about stopping
                case .trialOver:
                    if Licence.gated {
                        note("The Trial is over. Tiling and profiles are stopped until you enter a Licence key; windows stay where they are.")
                    }
                case .keyInvalid:
                    if Licence.gated {
                        note("The stored Licence key isn't valid. Tiling and profiles are stopped until you enter one that is.")
                    }
                case .revoked:
                    if Licence.gated {
                        note("This Licence has been revoked. Tiling and profiles are stopped.")
                    }
                case .updateWindowEnded(let licenceKey):
                    LabeledContent("Licensed to", value: licenceKey.email)
                    if Licence.gated {
                        note("The update window ended on \(Licence.day(licenceKey.updateWindowEnd)), before this version was released. Renew to use it, or use an earlier version.")
                    }
                }
                switch licence.checkout {
                case .buy?:
                    HStack {
                        Text("A Licence is £20 and covers every release in the 12 months after you buy it. Lifetime supporter is £40 and covers every future release.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Buy a Licence…") { licence.openCheckout() }
                    }
                case .renew?:
                    HStack {
                        Text("A Renewal is £12 and adds 12 months of updates, from the end of your update window or from the day you pay if it has ended. The new key arrives by email.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Renew…") { licence.openCheckout() }
                    }
                case nil:
                    EmptyView()
                }
                if let whyUngated = Licence.whyUngated {
                    Text(whyUngated)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Licence key", text: $key, prompt: Text("Paste your Licence key"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(3...6)
                    .font(.body.monospaced())
                HStack {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Activate") {
                        problem = licence.enter(key)
                        if problem == nil { key = "" }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text(licence.state.licence == nil ? "Enter a Licence key" : "Replace the Licence key")
            } footer: {
                Text("Your Licence key is in the email you got when you bought Spacetile. It's checked on this Mac and never sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
    }
}
