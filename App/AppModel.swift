import Foundation
import UIKit
import Network
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

    // MARK: - Settings (persisted)

    var wiFiOnlyDownloads = UserDefaults.standard.bool(forKey: "slsk.wiFiOnly") {
        didSet {
            UserDefaults.standard.set(wiFiOnlyDownloads, forKey: "slsk.wiFiOnly")
            applyNetworkPolicy()
        }
    }
    var downloadLimitKBs: UInt64 = UInt64(max(0, UserDefaults.standard.integer(forKey: "slsk.downLimit"))) {
        didSet {
            UserDefaults.standard.set(Int(downloadLimitKBs), forKey: "slsk.downLimit")
            Task { await transferEngine.setSpeedLimit(kbps: downloadLimitKBs) }
        }
    }
    private let pathMonitor = NWPathMonitor()
    private(set) var onCellular = false
    private var policyPaused = false

    let searchEngine: SearchEngine
    let searchModel: SearchModel
    let transferEngine: TransferEngine
    let transfersModel: TransfersModel
    let browseEngine: BrowseEngine
    let chatEngine: ChatEngine
    let chatModel: ChatModel
    let wishlistEngine: WishlistEngine
    let wishlistModel: WishlistModel
    let buddyEngine: BuddyEngine
    let buddyModel: BuddyModel
    let shareIndex: ShareIndex
    let uploadEngine: UploadEngine
    let uploadsModel: UploadsModel
    let libraryModel: LibraryModel
    let mediaStore: MediaStore
    let receivedMediaDir: URL
    let sentMediaDir: URL
    /// UI-test hook: a pre-registered media card the attach button sends
    /// directly (bypasses the photo picker, which tests can't drive).
    private(set) var uiTestSeedMedia: MediaCard?
    private let connection = ServerConnection()
    private let keychain = KeychainStore()
    private var stateTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: UInt64 = 2
    private(set) var userDisconnect = false
    private(set) var hasConnected = false
    /// True when credentials were restored from the Keychain at launch — the
    /// app must reconnect in place, never flash the login form.
    private(set) var restoringSession = false

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let receivedMediaDir = support.appendingPathComponent("ChatMedia")
        let sentMediaDir = support.appendingPathComponent("ChatMediaSent")
        try? FileManager.default.createDirectory(at: receivedMediaDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sentMediaDir, withIntermediateDirectories: true)
        self.receivedMediaDir = receivedMediaDir
        self.sentMediaDir = sentMediaDir
        let transfers = TransferEngine(server: connection, directory: documents.appendingPathComponent("Downloads"),
                                       mediaDirectory: receivedMediaDir)
        transferEngine = transfers
        mediaStore = MediaStore(transfers: transfers, receivedDir: receivedMediaDir, sentDir: sentMediaDir)
        let browse = BrowseEngine(server: connection)
        browseEngine = browse
        shareIndex = ShareIndex(storeURL: support.appendingPathComponent("shares.json"))
        let ups = UploadEngine(server: connection, index: shareIndex)
        uploadEngine = ups
        let coordinator = PortMapCoordinator(connection: connection)
        portMapCoordinator = coordinator
        searchEngine = SearchEngine(server: connection,
            onFileConnection: { link, pending in
                await transfers.handleDirectFile(link, pending: pending)
            },
            onUploadRequest: { link, user, file, pending in
                await ups.handleQueueDownload(link, username: user, filename: file, pending: pending)
            },
            onPierce: { link, ticket, pending in
                if await transfers.handleIndirectP(link, ticket: ticket, pending: pending) { return true }
                if await ups.handleIndirectUpload(link, ticket: ticket, pending: pending) { return true }
                return await browse.handleIndirectBrowse(link, ticket: ticket)
            },
            onListenPort: { port in
                await coordinator.map(port)
            })
        searchModel = SearchModel(engine: searchEngine, transferEngine: transfers)
        transfersModel = TransfersModel(engine: transfers)
        uploadsModel = UploadsModel(engine: ups)
        if CommandLine.arguments.contains("-UITestResetCredentials") {
            try? keychain.delete()
            try? FileManager.default.removeItem(at: support.appendingPathComponent("chat-history.json"))
        }
        chatEngine = ChatEngine(server: connection, storeURL: support.appendingPathComponent("chat-history.json"))
        chatModel = ChatModel(engine: chatEngine)
        wishlistEngine = WishlistEngine(server: connection, searchEngine: searchEngine,
                                        storeURL: support.appendingPathComponent("wishlist.json"))
        wishlistModel = WishlistModel(engine: wishlistEngine)
        let buddies = BuddyEngine(server: connection, storeURL: support.appendingPathComponent("buddies.json"))
        buddyEngine = buddies
        buddyModel = BuddyModel(engine: buddies)
        libraryModel = LibraryModel(directory: documents.appendingPathComponent("Downloads"))
        if CommandLine.arguments.contains("-UITestResetSettings") {
            UserDefaults.standard.removeObject(forKey: "slsk.wiFiOnly")
            UserDefaults.standard.removeObject(forKey: "slsk.downLimit")
            wiFiOnlyDownloads = false
            downloadLimitKBs = 0
        }
        if CommandLine.arguments.contains("-UITestSeedShare") {
            let seed = FileManager.default.temporaryDirectory.appendingPathComponent("SeedShare")
            try? FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
            try? Data((0..<2048).map { UInt8($0 % 251) }).write(to: seed.appendingPathComponent("seed track.mp3"))
            Task { await shareIndex.addRoot(seed.path); await announceShares() }
        }
        if CommandLine.arguments.contains("-UITestSeedLibrary") {
            let downloads = documents.appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try? Data((0..<4096).map { UInt8($0 % 251) }).write(to: downloads.appendingPathComponent("Seed Track.mp3"))
            libraryModel.refresh()
        }
        if CommandLine.arguments.contains("-UITestSeedMedia") {
            // 1×1 red PNG, registered and ready to send without the picker.
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            let name = "seed-photo.png"
            let url = sentMediaDir.appendingPathComponent(name)
            try? png.write(to: url)
            let virtual = "ChatMedia\\" + name
            Task { await shareIndex.registerMedia(virtualPath: virtual, localPath: url.path, size: UInt64(png.count)) }
            uiTestSeedMedia = MediaCard(username: "", path: virtual, size: UInt64(png.count), kind: .image, ext: "png")
        }
        // TTL cleanup: sent attachments live 7 days (recipients fetch them
        // live), received media 30 days.
        Task { [sentMediaDir, receivedMediaDir, shareIndex] in
            let now = Date()
            for (dir, days) in [(sentMediaDir, 7.0), (receivedMediaDir, 30.0)] {
                let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for url in urls {
                    let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                    if now.timeIntervalSince(mod) > days * 86_400 {
                        try? FileManager.default.removeItem(at: url)
                        if dir == sentMediaDir {
                            await shareIndex.unregisterMedia(virtualPath: "ChatMedia\\" + url.lastPathComponent)
                        }
                    }
                }
            }
        }
        if let saved = try? keychain.load() {
            username = saved.username
            password = saved.password
            restoringSession = true
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
        Task { await transferEngine.setSpeedLimit(kbps: downloadLimitKBs) }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor in
                self?.onCellular = cellular
                self?.applyNetworkPolicy()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "slsk.pathmonitor"))
    }

    /// Wi-Fi-only policy: pause downloads on cellular, resume when Wi-Fi
    /// returns (or the toggle is turned off).
    private func applyNetworkPolicy() {
        if wiFiOnlyDownloads && onCellular {
            if !policyPaused {
                policyPaused = true
                Task { await transferEngine.pauseAll() }
            }
        } else if policyPaused {
            policyPaused = false
            Task { await transferEngine.resumeAll() }
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

    /// Save a picked photo/video, register it for upload, and send the media
    /// card into the conversation (AD-16). Returns an error string or nil.
    func attachMedia(data: Data, ext: String, kind: MediaCard.Kind, to conversationID: String) async -> String? {
        let cap: Int = kind == .image ? 15_000_000 : 100_000_000
        guard data.count <= cap else {
            return kind == .image ? "Photos are limited to 15 MB." : "Videos are limited to 100 MB."
        }
        guard !username.isEmpty else { return "Not connected." }
        let name = UUID().uuidString + "." + ext
        let url = sentMediaDir.appendingPathComponent(name)
        do { try data.write(to: url) } catch { return "Couldn't save the attachment." }
        let virtual = "ChatMedia\\" + name
        await shareIndex.registerMedia(virtualPath: virtual, localPath: url.path, size: UInt64(data.count))
        let card = MediaCard(username: username, path: virtual, size: UInt64(data.count), kind: kind, ext: ext)
        await chatEngine.sendMedia(card, to: conversationID)
        return nil
    }

    func shareCounts() async -> (files: Int, folders: Int) {
        (await shareIndex.files.count, await shareIndex.folderCount)
    }

    private func announceShares() async {
        let files = await shareIndex.files.count
        let folders = await shareIndex.folderCount
        try? await connection.send(frame: ServerMessages.sharedFoldersFiles(folders: UInt32(folders), files: UInt32(files)))
    }

    // MARK: - NAT port mapping

    private let portMapCoordinator: PortMapCoordinator

    func signOut() {
        try? keychain.delete()
        username = ""
        password = ""
        disconnect()
    }

    // MARK: - App lifecycle (background downloads)

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Backgrounded: keep downloading for the system grace period (~30s);
    /// when it expires, pause everything cleanly (.partial files preserved).
    func sceneBackgrounded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "downloads-grace") { [weak self] in
            Task { await self?.transferEngine.pauseAll() }
            self?.endBackgroundTask()
        }
    }

    /// Foregrounded: resume anything paused while away.
    func sceneForegrounded() {
        endBackgroundTask()
        Task {
            await transferEngine.resumeAll()
            applyNetworkPolicy()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
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
            Task { await buddyEngine.refreshAll() }
            // Accept private-room invitations (server default is off).
            Task { await chatEngine.setInvitationsEnabled(true) }
            // Rejoin persisted rooms — the server forgets memberships across sessions.
            Task { await chatEngine.rejoinRooms() }
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

/// NAT-PMP on the listener port; on success re-advertises the EXTERNAL port
/// to the server and refreshes at half the lease. Silent degradation: without
/// a mapping the indirect (server-brokered) path keeps working.
private actor PortMapCoordinator {
    private let connection: ServerConnection
    private var task: Task<Void, Never>?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func map(_ port: UInt16) async {
        task?.cancel()
        guard let mapping = await PortMapper().mapTCP(internalPort: port) else { return }
        try? await connection.send(frame: ServerMessages.setListenPort(UInt32(mapping.externalPort)))
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(mapping.lifetime) * 500_000_000) } catch { return }
            await self?.map(port)
        }
    }
}