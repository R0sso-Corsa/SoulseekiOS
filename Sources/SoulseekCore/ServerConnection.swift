import Foundation
import Network
import SoulseekProtocol

/// Actor-isolated connection to the Soulseek login server.
/// Lifecycle: connect → Login(1) → post-login handshake → connected (5-min ping).
/// The UI consumes `states`; peer-related server messages surface on `events`.
public actor ServerConnection {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(greeting: String, publicIP: String, privileged: Bool)
        case failed(String)
        case kicked
    }

    public enum ServerEvent: Sendable {
        case connectToPeer(ConnectToPeerRequest)
        case cannotConnect(ticket: UInt32)
        case privateMessage(PrivateMessage)
        case roomMessage(RoomMessage)
        case roomJoined(RoomJoined)
        case roomLeft(room: String)
        case userJoinedRoom(UserJoinedRoom)
        case userLeftRoom(UserLeftRoom)
        case roomList(RoomList)
    }

    public enum ConnectionError: Error, LocalizedError {
        case notConnected, addressTimeout

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to the server"
            case .addressTimeout: return "Couldn't reach the user (address lookup timed out)"
            }
        }
    }

    public private(set) var state: State = .disconnected
    public private(set) var username = ""
    public nonisolated let states: AsyncStream<State>
    public nonisolated let fileEvents: AsyncStream<ConnectToPeerRequest>
    private let stateContinuation: AsyncStream<State>.Continuation
    private let fileEventContinuation: AsyncStream<ConnectToPeerRequest>.Continuation
    /// Multicast event hub: SearchEngine, ChatEngine, … each get their own
    /// stream (a single AsyncStream would split events between consumers).
    private var eventStreams: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]

    private var connection: NWConnection?
    private var reader = FrameReader()
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var loginContinuation: CheckedContinuation<Void, Never>?
    private var addressRequests: [String: CheckedContinuation<PeerAddressReply, Error>] = [:]
    private var statsRequests: [String: CheckedContinuation<UserStats, Error>] = [:]
    private var statusRequests: [String: CheckedContinuation<UserStatus, Error>] = [:]

    public init() {
        var continuation: AsyncStream<State>.Continuation?
        states = AsyncStream { continuation = $0 }
        stateContinuation = continuation!
        var fileCont: AsyncStream<ConnectToPeerRequest>.Continuation?
        fileEvents = AsyncStream { fileCont = $0 }
        fileEventContinuation = fileCont!
    }

    deinit {
        stateContinuation.finish()
        for cont in eventStreams.values { cont.finish() }
        fileEventContinuation.finish()
    }

    /// Subscribe to server events. Each caller receives EVERY event.
    public func makeEventStream() -> AsyncStream<ServerEvent> {
        let id = UUID()
        return AsyncStream { cont in
            self.eventStreams[id] = cont
            cont.onTermination = { _ in
                Task { await self.dropEventStream(id) }
            }
        }
    }

    private func dropEventStream(_ id: UUID) {
        eventStreams[id] = nil
    }

    private func broadcast(_ event: ServerEvent) {
        for cont in eventStreams.values { cont.yield(event) }
    }

    /// Connect and log in. Returns once the login response (or a failure) is
    /// processed; afterwards `state` drives the UI. Safe to call again after
    /// failure/kick/disconnect.
    public func connect(username: String, password: String, host: String = "server.slsknet.org", port: UInt16 = 2242) async {
        await tearDown()
        self.username = username
        reader = FrameReader()
        setState(.connecting)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            setState(.failed("invalid port"))
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn

        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            conn.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    once.fire { cont.resume(returning: true) }
                case .failed(let error):
                    once.fire { cont.resume(returning: false) }
                    Task { await self?.transportFailed(error.localizedDescription) }
                case .cancelled:
                    once.fire { cont.resume(returning: false) }
                default:
                    break // .setup/.waiting/.preparing: NWConnection retries on its own
                }
            }
            conn.start(queue: DispatchQueue(label: "slsk.server.connection"))
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                once.fire { cont.resume(returning: false) }
            }
        }
        guard ready, connection != nil else {
            conn.cancel()
            if state == .connecting { setState(.failed("connection failed")) }
            return
        }

        receiveTask = Task { await self.receiveLoop() }
        do {
            try await send(Login.frame(username: username, password: password))
        } catch {
            await fail("send login: \(error.localizedDescription)")
            return
        }
        let loginTimeout = Task {
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch { return } // cancelled: login completed
            await self.loginTimedOut()
        }
        await withCheckedContinuation { loginContinuation = $0 }
        loginTimeout.cancel()
    }

    private func loginTimedOut() async {
        if loginContinuation != nil, state == .connecting {
            setState(.failed("login timed out"))
            await tearDown(keepState: true)
            resumeLogin()
        }
    }

    public func disconnect() async {
        await tearDown()
    }

    /// Send a raw frame to the server (SearchEngine and later slices).
    public func send(frame: Data) async throws {
        try await send(frame)
    }

    /// Resolve a peer's address via GetPeerAddress(3); 10s timeout.
    public func peerAddress(for username: String) async throws -> PeerAddressReply {
        try await send(ServerMessages.getPeerAddress(username: username))
        return try await withCheckedThrowingContinuation { cont in
            addressRequests[username] = cont
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self.timeoutAddressRequest(username)
            }
        }
    }

    private func timeoutAddressRequest(_ username: String) async {
        if let cont = addressRequests.removeValue(forKey: username) {
            cont.resume(throwing: ConnectionError.addressTimeout)
        }
    }

    /// Resolve a user's upload stats via GetUserStats(36); 10s timeout.
    public func userStats(for username: String) async throws -> UserStats {
        try await send(ServerMessages.getUserStats(username: username))
        return try await withCheckedThrowingContinuation { cont in
            statsRequests[username] = cont
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self.timeoutStatsRequest(username)
            }
        }
    }

    /// Resolve a user's online/away status via GetUserStatus(7); 10s timeout.
    public func userStatus(for username: String) async throws -> UserStatus {
        try await send(ServerMessages.getUserStatus(username: username))
        return try await withCheckedThrowingContinuation { cont in
            statusRequests[username] = cont
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self.timeoutStatusRequest(username)
            }
        }
    }

    private func timeoutStatsRequest(_ username: String) async {
        if let cont = statsRequests.removeValue(forKey: username) {
            cont.resume(throwing: ConnectionError.addressTimeout)
        }
    }

    private func timeoutStatusRequest(_ username: String) async {
        if let cont = statusRequests.removeValue(forKey: username) {
            cont.resume(throwing: ConnectionError.addressTimeout)
        }
    }

    // MARK: - Internals

    private func setState(_ newState: State) {
        state = newState
        stateContinuation.yield(newState)
    }

    private func resumeLogin() {
        loginContinuation?.resume()
        loginContinuation = nil
    }

    private func tearDown(keepState: Bool = false) async {
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        resumeLogin()
        if !keepState { setState(.disconnected) }
    }

    private func transportFailed(_ reason: String) async {
        guard connection != nil else { return } // deliberate disconnect
        await fail(reason)
    }

    private func fail(_ reason: String) async {
        setState(.failed(reason))
        await tearDown(keepState: true)
    }

    private func send(_ data: Data) async throws {
        guard let conn = connection else { throw ConnectionError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let conn = connection else { return }
            let (data, error): (Data?, NWError?) = await withCheckedContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    cont.resume(returning: (data, error))
                }
            }
            if Task.isCancelled || connection == nil { return }
            if let error {
                await transportFailed(error.localizedDescription)
                return
            }
            guard let data, !data.isEmpty else {
                await transportFailed("server closed connection")
                return
            }
            reader.append(data)
            do {
                while let frame = try reader.next() {
                    await handle(frame)
                }
            } catch {
                await fail("codec: \(error)")
                return
            }
        }
    }

    private func handle(_ frame: Frame) async {
        switch frame.code {
        case 1: // Login response
            do {
                let response = try LoginResponse(payload: frame.payload)
                if response.success {
                    for data in Handshake.frames(username: username) {
                        try await send(data)
                    }
                    setState(.connected(
                        greeting: response.greeting ?? "",
                        publicIP: response.ip ?? "",
                        privileged: response.privileged ?? false
                    ))
                    startPing()
                } else {
                    setState(.failed(response.reason ?? "login failed"))
                    await tearDown(keepState: true)
                }
            } catch {
                await fail("login decode: \(error)")
            }
            resumeLogin()
        case 41: // Kicked (duplicate login elsewhere)
            setState(.kicked)
            await tearDown(keepState: true)
            resumeLogin()
        case 3: // GetPeerAddress reply
            if let reply = try? PeerAddressReply(payload: frame.payload),
               let cont = addressRequests.removeValue(forKey: reply.username) {
                cont.resume(returning: reply)
            }
        case 36: // GetUserStats reply
            if let reply = try? UserStats(payload: frame.payload),
               let cont = statsRequests.removeValue(forKey: reply.username) {
                cont.resume(returning: reply)
            }
        case 7: // GetUserStatus reply
            if let reply = try? UserStatus(payload: frame.payload),
               let cont = statusRequests.removeValue(forKey: reply.username) {
                cont.resume(returning: reply)
            }
        case 18: // ConnectToPeer: indirect connection request; route by type
            if let request = try? ConnectToPeerRequest(payload: frame.payload) {
                if request.type == "F" {
                    fileEventContinuation.yield(request)
                } else {
                    broadcast(.connectToPeer(request))
                }
            }
        case 1001: // CannotConnect
            var r = MessageReader(frame.payload)
            if let ticket = try? r.u32() {
                broadcast(.cannotConnect(ticket: ticket))
            }
        case 22: // PrivateMessage
            if let pm = try? PrivateMessage(payload: frame.payload) {
                broadcast(.privateMessage(pm))
            }
        case 13: // SayChatroom
            if let rm = try? RoomMessage(payload: frame.payload) {
                broadcast(.roomMessage(rm))
            }
        case 14: // JoinRoom reply
            if let rj = try? RoomJoined(payload: frame.payload) {
                broadcast(.roomJoined(rj))
            }
        case 15: // LeaveRoom reply
            var r = MessageReader(frame.payload)
            if let room = try? r.string() {
                broadcast(.roomLeft(room: room))
            }
        case 16: // UserJoinedRoom
            if let uj = try? UserJoinedRoom(payload: frame.payload) {
                broadcast(.userJoinedRoom(uj))
            }
        case 17: // UserLeftRoom
            if let ul = try? UserLeftRoom(payload: frame.payload) {
                broadcast(.userLeftRoom(ul))
            }
        case 64: // RoomList (post-login burst + on request)
            if let list = try? RoomList(payload: frame.payload) {
                broadcast(.roomList(list))
            }
        default:
            break // post-login burst (RoomList, PrivilegedUsers, …) — later slices consume these
        }
    }

    private func startPing() {
        pingTask = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
                    if Task.isCancelled { return }
                    try await self.send(ServerMessages.ping())
                }
            } catch {
                return // cancelled or send failed — ping loop exits quietly
            }
        }
    }
}

/// Resumes a continuation exactly once across racing Network.framework callbacks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if !fired {
            fired = true
            body()
        }
    }
}