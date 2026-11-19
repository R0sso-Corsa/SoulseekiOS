import Foundation
import SoulseekCore
import SoulseekProtocol

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
    let transferEngine: TransferEngine
    let transfersModel: TransfersModel
    let browseEngine: BrowseEngine
    let chatEngine: ChatEngine
    let chatModel: ChatModel
    private let connection = ServerConnection()
    private let keychain = KeychainStore()
    private var stateTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: UInt64 = 2
    private var userDisconnect = false
    private var hasConnected = false

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let transfers = TransferEngine(server: connection, directory: documents.appendingPathComponent("Downloads"))
        transferEngine = transfers
        browseEngine = BrowseEngine(server: connection)
        searchEngine = SearchEngine(server: connection) { link, pending in
            await transfers.handleDirectFile(link, pending: pending)
        }
        searchModel = SearchModel(engine: searchEngine, transferEngine: transfers)
        transfersModel = TransfersModel(engine: transfers)
        chatEngine = ChatEngine(server: connection)
        chatModel = ChatModel(engine: chatEngine)
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
        userDisconnect = false
        reconnectTask?.cancel()
        Task { await connection.connect(username: username, password: password) }
    }

    func disconnect() {
        userDisconnect = true
        reconnectTask?.cancel()
        Task { await connection.disconnect() }
    }

    // MARK: - User info + browse (facade over the connection actor)

    func userStats(for username: String) async throws -> UserStats {
        try await connection.userStats(for: username)
    }

    func userStatus(for username: String) async throws -> UserStatus {
        try await connection.userStatus(for: username)
    }

    func browseShares(of username: String) async throws -> [SharedFolder] {
        try await browseEngine.browse(username: username)
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
            scheduleReconnect()
        case .connecting:
            phase = .connecting
        case .connected(let greeting, let publicIP, let privileged):
            hasConnected = true
            reconnectDelay = 2
            phase = .connected(greeting: greeting, publicIP: publicIP, privileged: privileged)
            Task { await searchEngine.startListening() }
        case .failed(let reason):
            phase = .failed(reason)
            Task { await searchEngine.stopListening() }
            scheduleReconnect()
        case .kicked:
            // Duplicate login elsewhere — reconnecting would kick-loop.
            phase = .kicked
            Task { await searchEngine.stopListening() }
        }
    }

    /// slskd-style auto-reconnect: exponential backoff 2s→30s after an
    /// unexpected drop. Never fires for sign-out or kick.
    private func scheduleReconnect() {
        guard hasConnected, !userDisconnect, !username.isEmpty, !password.isEmpty else { return }
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            guard let self, !self.userDisconnect else { return }
            switch self.phase {
            case .loggedOut, .failed:
                self.connect()
            default:
                break
            }
        }
    }
}