import SwiftUI

struct ConnectedView: View {
    let greeting: String
    let publicIP: String
    let privileged: Bool
    let username: String
    let onDisconnect: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        List {
            Section {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("connectedLabel")
                LabeledContent("User", value: username)
                LabeledContent("Public IP") {
                    Text(publicIP)
                        .accessibilityIdentifier("publicIPValue")
                }
                LabeledContent("Privileged", value: privileged ? "yes" : "no")
            }

            if !greeting.isEmpty {
                Section("Message of the day") {
                    Text(greeting)
                }
            }

            Section {
                Button("Disconnect", action: onDisconnect)
                    .accessibilityIdentifier("disconnectButton")
                Button("Sign out (forget credentials)", role: .destructive, action: onSignOut)
                    .accessibilityIdentifier("signOutButton")
            }

            Section("Next") {
                Text("Search + downloads are the next slices (backlog #2–5).")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Soulseek")
    }
}