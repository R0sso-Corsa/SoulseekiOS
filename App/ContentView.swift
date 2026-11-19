import SwiftUI
import SoulseekProtocol

/// M1 scaffold shell. Proves the app target links the wire codec; the login
/// vertical slice (backlog #1) replaces the "Next" section with real UI.
struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Soulseek iOS") {
                    LabeledContent("Stage", value: "M1 scaffold")
                    LabeledContent("Codec", value: "SoulseekProtocol linked")
                    LabeledContent("Client version", value: "\(Login.clientVersion).\(Login.minorVersion)")
                    LabeledContent("Server", value: "server.slsknet.org:2242")
                }
                Section("Next") {
                    Text("Login vertical slice (backlog #1): Keychain credentials + live connection.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Soulseek")
        }
    }
}

#Preview {
    ContentView()
}