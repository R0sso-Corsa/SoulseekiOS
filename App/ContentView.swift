import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationStack {
            switch model.phase {
            case .connected(let greeting, let publicIP, let privileged):
                ConnectedView(
                    greeting: greeting,
                    publicIP: publicIP,
                    privileged: privileged,
                    username: model.username,
                    onDisconnect: model.disconnect,
                    onSignOut: model.signOut
                )
            default:
                LoginView(model: model)
            }
        }
    }
}

#Preview {
    ContentView()
}