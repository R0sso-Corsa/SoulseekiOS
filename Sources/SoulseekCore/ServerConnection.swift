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
    }

    public enum ConnectionError: Error { case notConnected, addressTimeout }

    public private(set) var state: State = .disconnected
    public private(set) var username = ""
    public nonisolated let states: AsyncStream<State>
    public nonisolated let events: AsyncStream<ServerEvent>
    public nonisolated let fileEvents: AsyncStream<ConnectToPeerRequest>
    private let stateContinuation: AsyncStream<State>.Continuation
    private let eventContinuation: AsyncStream<ServerEvent>.Continuation
    private let fileEventContinuation: AsyncStream<ConnectToPeerRequest>.Continuation

    private var connection: NWConnection?
    private var reader = FrameReader()
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var loginContinuation: CheckedContinuation<Void, Never>?
    private var addressRequests: [String: CheckedContinuation<PeerAddressReply, Error>] = [:]

    public init() {
        var continuation: AsyncStream<State>.Continuation?
        states = AsyncStream { continuation = $0 }
        stateContinuation = continuation!
        var eventCont: AsyncStream<ServerEvent>.Continuation?
        events = AsyncStream { eventCont = $0 }
        eventContinuation = eventCont!
        var fileCont: AsyncStream<ConnectToPeerRequest>.Continuation?
        fileEvents = AsyncStream { fileCont = $0 }
        fileEventContinuation = fileCont!
    }

    deinit {
        stateContinuation.finish()
        eventContinuation.finish()
        fileEventContinuation.finish()
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
        }
        guard ready, connection != nil else {
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
        await withCheckedContinuation { loginContinuation = $0 }
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
        case 18: // ConnectToPeer: indirect connection request; route by type
            if let request = try? ConnectToPeerRequest(payload: frame.payload) {
                if request.type == "F" {
                    fileEventContinuation.yield(request)
                } else {
                    eventContinuation.yield(.connectToPeer(request))
                }
            }
        case 1001: // CannotConnect
            var r = MessageReader(frame.payload)
            if let ticket = try? r.u32() {
                eventContinuation.yield(.cannotConnect(ticket: ticket))
            }
        default:
            break // post-login burst (RoomList, PrivilegedUsers, …) — later slices consume these
        }
    }

    private func startPing() {
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
                if Task.isCancelled { return }
                do {
                    try await self.send(ServerMessages.ping())
                } catch {
                    return
                }
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