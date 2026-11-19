import SwiftUI

struct ConnectedView: View {
    let greeting: String
    let publicIP: String
    let privileged: Bool
    let username: String
    let onDisconnect: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("connectedLabel")
                        LabeledContent("User", value: username)
                        LabeledContent("Public IP") {
                            Text(publicIP)
                                .accessibilityIdentifier("publicIPValue")
                        }
                        LabeledContent("Privileged", value: privileged ? "yes" : "no")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(.green.opacity(0.12)), in: .rect(cornerRadius: 20))

                    if !greeting.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Message of the day")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(greeting)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }

                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 12) {
                            Button("Disconnect", action: onDisconnect)
                                .buttonStyle(.glass)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("disconnectButton")
                            Button("Sign out (forget credentials)", role: .destructive, action: onSignOut)
                                .buttonStyle(.glass)
                                .tint(.red)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("signOutButton")
                        }
                    }

                    Text("Downloads are the next slice (backlog #4–5).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 24)
                }
                .padding()
            }
        }
        .navigationTitle("Status")
    }
}