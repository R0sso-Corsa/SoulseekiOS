import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        switch model.phase {
        case .connected(let greeting, let publicIP, let privileged):
            TabView {
                NavigationStack {
                    SearchView(model: model.searchModel)
                }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                NavigationStack {
                    ConnectedView(
                        greeting: greeting,
                        publicIP: publicIP,
                        privileged: privileged,
                        username: model.username,
                        onDisconnect: model.disconnect,
                        onSignOut: model.signOut
                    )
                }
                .tabItem { Label("Status", systemImage: "person.crop.circle") }
                NavigationStack {
                    TransfersView(model: model.transfersModel)
                }
                .tabItem { Label("Transfers", systemImage: "arrow.down.circle") }
            }
            .tint(.orange)
        default:
            NavigationStack {
                LoginView(model: model)
            }
            .tint(.orange)
        }
    }
}

#Preview {
    ContentView()
}