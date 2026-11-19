import SwiftUI
import SoulseekProtocol

struct LoginView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Soulseek account") {
                TextField("Username", text: $model.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("usernameField")
                SecureField("Password", text: $model.password)
                    .accessibilityIdentifier("passwordField")
            }

            Section {
                Button {
                    model.connect()
                } label: {
                    if model.phase == .connecting {
                        HStack {
                            ProgressView()
                            Text("Connecting…")
                        }
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(!model.canConnect)
                .accessibilityIdentifier("connectButton")
            } footer: {
                Text("New usernames are registered automatically on first connect.")
            }

            if case .failed(let reason) = model.phase {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("errorText")
                }
            }

            if case .kicked = model.phase {
                Section {
                    Label("Logged in elsewhere — this session was kicked.", systemImage: "person.crop.circle.badge.xmark")
                        .accessibilityIdentifier("kickedText")
                }
            }

            if let keychainError = model.keychainError {
                Section {
                    Label(keychainError, systemImage: "key.slash")
                        .foregroundStyle(.orange)
                }
            }

            Section("Client") {
                LabeledContent("Version", value: "\(Login.clientVersion).\(Login.minorVersion)")
                LabeledContent("Server", value: "server.slsknet.org:2242")
            }
        }
        .navigationTitle("Soulseek")
    }
}