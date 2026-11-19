import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    private var connectionInfo: (greeting: String, publicIP: String, privileged: Bool) {
        if case .connected(let greeting, let publicIP, let privileged) = model.phase {
            return (greeting, publicIP, privileged)
        }
        return ("", "", false)
    }

    private var isConnected: Bool {
        if case .connected = model.phase { return true }
        return false
    }

    private var hasCredentials: Bool {
        !model.username.isEmpty && !model.password.isEmpty
    }

    /// The login form appears only when there is nothing to restore: first
    /// launch, sign-out, kick, or a manual login still in progress. Restored
    /// sessions and mid-use reconnects stay in the app with a status banner.
    private var showLogin: Bool {
        if case .kicked = model.phase { return true }
        if !hasCredentials { return true }
        if model.userDisconnect { return true }
        return !model.restoringSession && !model.hasConnected
    }

    private var bannerText: String? {
        guard hasCredentials, !isConnected, !showLogin else { return nil }
        switch model.phase {
        case .connecting: return "Connecting…"
        case .failed(let reason): return reason
        default: return "Reconnecting…"
        }
    }

    var body: some View {
        // TabView stays mounted across reconnects so the selected tab (and
        // each tab's navigation state) survives transient drops.
        ZStack {
            TabView(selection: Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 })) {
                NavigationStack {
                    SearchView(model: model.searchModel, appModel: model)
                }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(0)
                NavigationStack {
                    ChatView(model: model.chatModel, appModel: model)
                }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(1)
                NavigationStack {
                    ConnectedView(
                        greeting: connectionInfo.greeting,
                        publicIP: connectionInfo.publicIP,
                        privileged: connectionInfo.privileged,
                        username: model.username,
                        onDisconnect: model.disconnect,
                        onSignOut: model.signOut
                    )
                }
                .tabItem { Label("Status", systemImage: "person.crop.circle") }
                .tag(2)
                NavigationStack {
                    TransfersView(model: model.transfersModel, appModel: model)
                }
                .tabItem { Label("Transfers", systemImage: "arrow.down.circle") }
                .tag(3)
            }
            .tint(.orange)
            .opacity(showLogin ? 0 : 1)
            .allowsHitTesting(isConnected)

            if showLogin {
                NavigationStack {
                    LoginView(model: model)
                }
                .tint(.orange)
            }

            if let text = bannerText {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        if case .connecting = model.phase {
                            ProgressView().controlSize(.small)
                        }
                        Text(text)
                            .font(.footnote)
                            .accessibilityIdentifier("connectionBanner")
                        if case .failed = model.phase {
                            Button("Sign out") { model.signOut() }
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 95)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}