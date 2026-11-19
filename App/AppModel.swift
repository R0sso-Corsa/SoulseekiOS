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
    /// Survives reconnects — a transient drop must not reset the user's tab.
    var selectedTab = 0

    let searchEngine: SearchEngine
    let searchModel: SearchModel
    let transferEngine: TransferEngine
    let transfersModel: TransfersModel
    let browseEngine: BrowseEngine
    let chatEngine: ChatEngine
    let chatModel: ChatModel
    let wishlistEngine: WishlistEngine
    let wishlistModel: WishlistModel
    let shareIndex: ShareIndex
    let uploadEngine: UploadEngine
    let uploadsModel: UploadsModel
    private let connection = ServerConnection()
    private let keychain = KeychainStore()
    private var stateTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: UInt64 = 2
    private var userDisconnect = false
    private var hasConnected = false

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let transfers = TransferEngine(server: connection, directory: documents.appendingPathComponent("Downloads"))
        transferEngine = transfers
        browseEngine = BrowseEngine(server: connection)
        shareIndex = ShareIndex(storeURL: support.appendingPathComponent("shares.json"))
        let ups = UploadEngine(server: connection, index: shareIndex)
        uploadEngine = ups
        searchEngine = SearchEngine(server: connection,
            onFileConnection: { link, pending in
                await transfers.handleDirectFile(link, pending: pending)
            },
            onUploadRequest: { link, user, file, pending in
                await ups.handleQueueDownload(link, username: user, filename: file, pending: pending)
            },
            onPierce: { link, ticket, pending in
                if await transfers.handleIndirectP(link, ticket: ticket, pending: pending) { return true }
                return await ups.handleIndirectUpload(link, ticket: ticket, pending: pending)
            })
        searchModel = SearchModel(engine: searchEngine, transferEngine: transfers)
        transfersModel = TransfersModel(engine: transfers)
        uploadsModel = UploadsModel(engine: ups)
        chatEngine = ChatEngine(server: connection)
        chatModel = ChatModel(engine: chatEngine)
        wishlistEngine = WishlistEngine(server: connection, searchEngine: searchEngine,
                                        storeURL: support.appendingPathComponent("wishlist.json"))
        wishlistModel = WishlistModel(engine: wishlistEngine)
        if CommandLine.arguments.contains("-UITestResetCredentials") {
            try? keychain.delete()
        }
        if CommandLine.arguments.contains("-UITestSeedShare") {
            let seed = FileManager.default.temporaryDirectory.appendingPathComponent("SeedShare")
            try? FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
            try? Data((0..<2048).map { UInt8($0 % 251) }).write(to: seed.appendingPathComponent("seed track.mp3"))
            Task { await shareIndex.addRoot(seed.path); await announceShares() }
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
        // Saved credentials ⇒ auto-connect on launch (closing the app must
        // not sign the user out). UI tests reset credentials and log in manually.
        if !username.isEmpty, !password.isEmpty,
           !CommandLine.arguments.contains("-UITestResetCredentials") {
            connect()
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

    // MARK: - Sharing / uploads

    /// Copies the picked folder into Documents/Shares (the picker's security
    /// scope is temporary; bookmarks are a later upgrade) and indexes it.
    func addShareRoot(_ url: URL) {
        Task {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let sharesDir = documents.appendingPathComponent("Shares")
            try? FileManager.default.createDirectory(at: sharesDir, withIntermediateDirectories: true)
            var dest = sharesDir.appendingPathComponent(url.lastPathComponent)
            var i = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = sharesDir.appendingPathComponent("\(url.lastPathComponent)-\(i)")
                i += 1
            }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                await shareIndex.addRoot(dest.path)
                await announceShares()
            } catch {
                // Copy failed (permissions/size) — the sheet shows no new root.
            }
        }
    }

    func removeShareRoot(_ path: String) {
        Task {
            await shareIndex.removeRoot(path)
            await announceShares()
        }
    }

    func shareRoots() async -> [String] { await shareIndex.roots }

    func shareCounts() async -> (files: Int, folders: Int) {
        (await shareIndex.files.count, await shareIndex.folderCount)
    }

    private func announceShares() async {
        let files = await shareIndex.files.count
        let folders = await shareIndex.folderCount
        try? await connection.send(frame: ServerMessages.sharedFoldersFiles(folders: UInt32(folders), files: UInt32(files)))
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
            Task { await announceShares() }
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