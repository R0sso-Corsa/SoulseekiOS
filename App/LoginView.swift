import SwiftUI
import SoulseekProtocol

struct LoginView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Image(systemName: "bird.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Text("Soulseek")
                            .font(.largeTitle.bold())
                        Text("Dig for music on the P2P network")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    VStack(spacing: 0) {
                        TextField("Username", text: $model.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding()
                            .accessibilityIdentifier("usernameField")
                        Divider()
                            .padding(.leading)
                        SecureField("Password", text: $model.password)
                            .padding()
                            .accessibilityIdentifier("passwordField")
                    }
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))

                    Button {
                        model.connect()
                    } label: {
                        HStack(spacing: 8) {
                            if model.phase == .connecting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(model.phase == .connecting ? "Connecting…" : "Connect")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canConnect)
                    .accessibilityIdentifier("connectButton")

                    if case .failed(let reason) = model.phase {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular.tint(.red.opacity(0.25)), in: .capsule)
                            .accessibilityIdentifier("errorText")
                    }

                    if case .kicked = model.phase {
                        Label("Logged in elsewhere — this session was kicked.", systemImage: "person.crop.circle.badge.xmark")
                            .font(.footnote)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular.tint(.red.opacity(0.25)), in: .capsule)
                            .accessibilityIdentifier("kickedText")
                    }

                    if let keychainError = model.keychainError {
                        Label(keychainError, systemImage: "key.slash")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    Text("New usernames are registered automatically on first connect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 6) {
                        Text("v\(Login.clientVersion).\(Login.minorVersion)")
                        Text("·")
                        Text("server.slsknet.org:2242")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}