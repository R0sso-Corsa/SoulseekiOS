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
            .opacity(isConnected ? 1 : 0)
            .allowsHitTesting(isConnected)

            if !isConnected {
                NavigationStack {
                    LoginView(model: model)
                }
                .tint(.orange)
            }
        }
    }
}

#Preview {
    ContentView()
}