import Foundation
import SoulseekCore

/// App-level state. Bridges the ServerConnection actor's state stream into
/// SwiftUI observation; credentials live in the Keychain. Owns the search
/// engine and starts/stops its listener with the connection lifecycle.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loggedOut
        case connecting
        case connected(greeting: String, publicIP: String, privileged: Bool)
        case failed(String)
        case kicked
    }

    var phase: Phase = .loggedOut
    var username: String = ""
    var password: String = ""
    var keychainError: String?

    let searchEngine: SearchEngine
    let searchModel: SearchModel
    private let connection = ServerConnection()
    private let keychain = KeychainStore()
    private var stateTask: Task<Void, Never>?

    init() {
        searchEngine = SearchEngine(server: connection)
        searchModel = SearchModel(engine: searchEngine)
        if CommandLine.arguments.contains("-UITestResetCredentials") {
            try? keychain.delete()
        }
        if let saved = try? keychain.load() {
            username = saved.username
            password = saved.password
        }
        stateTask = Task { [weak self] in
            guard let stream = self?.connection.states else { return }
            for await state in stream {
                self?.apply(state)
            }
        }
    }

    var canConnect: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && phase != .connecting
    }

    func connect() {
        guard canConnect else { return }
        do {
            try keychain.save(username: username, password: password)
            keychainError = nil
        } catch {
            keychainError = "Keychain save failed: \(error)"
        }
        Task { await connection.connect(username: username, password: password) }
    }

    func disconnect() {
        Task { await connection.disconnect() }
    }

    func signOut() {
        try? keychain.delete()
        username = ""
        password = ""
        disconnect()
    }

    private func apply(_ state: ServerConnection.State) {
        switch state {
        case .disconnected:
            phase = .loggedOut
            Task { await searchEngine.stopListening() }
        case .connecting:
            phase = .connecting
        case .connected(let greeting, let publicIP, let privileged):
            phase = .connected(greeting: greeting, publicIP: publicIP, privileged: privileged)
            Task { await searchEngine.startListening() }
        case .failed(let reason):
            phase = .failed(reason)
            Task { await searchEngine.stopListening() }
        case .kicked:
            phase = .kicked
            Task { await searchEngine.stopListening() }
        }
    }
}