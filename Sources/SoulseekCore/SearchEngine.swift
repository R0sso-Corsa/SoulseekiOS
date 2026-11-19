import Foundation
import Network
import SoulseekProtocol

/// Search slice: sends FileSearch via the server, receives PeerSearchReply
/// over indirect (ConnectToPeer → outbound dial → PierceFw) or direct peer
/// connections, decodes zlib results, publishes state. Peer handling lives
/// here until the transfer slice needs a shared PeerConnections layer.
public actor SearchEngine {
    public struct State: Equatable, Sendable {
        public var query: String?
        public var ticket: UInt32?
        public var isSearching = false
        public var replies: [SearchReply] = []
        public var finished = false
        public var listenPort: UInt16 = 0

        public init() {}
    }

    public private(set) var state = State()
    public nonisolated let states: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation

    private let server: ServerConnection
    private var eventTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var listener: NWListener?
    private var peerTasks: [UUID: Task<Void, Never>] = [:]
    private var peerConns: [UUID: NWConnection] = [:]

    private let onFileConnection: (@Sendable (PeerLink, Data) async -> Void)?

    public init(server: ServerConnection, onFileConnection: (@Sendable (PeerLink, Data) async -> Void)? = nil) {
        self.server = server
        self.onFileConnection = onFileConnection
        var continuation: AsyncStream<State>.Continuation?
        states = AsyncStream { continuation = $0 }
        stateContinuation = continuation!
        eventTask = Task { await self.consumeEvents() }
    }

    deinit {
        stateContinuation.finish()
    }

    // MARK: - Listening

    /// Ephemeral-port listener; advertises the real port to the server once
    /// ready. Direct inbound only works on reachable networks — indirect
    /// (we dial out) is the normal path behind NAT.
    public func startListening() async {
        guard listener == nil else { return }
        guard let newListener = try? NWListener(using: .tcp, on: .any) else { return }
        listener = newListener
        newListener.newConnectionHandler = { [weak self] conn in
            Task { await self?.handleDirect(conn) }
        }
        newListener.stateUpdateHandler = { [weak self] listenerState in
            if case .ready = listenerState, let port = newListener.port {
                Task { await self?.advertise(port: port.rawValue) }
            }
        }
        newListener.start(queue: DispatchQueue(label: "slsk.peer.listener"))
    }

    public func stopListening() async {
        listener?.cancel()
        listener = nil
        if state.listenPort != 0 {
            state.listenPort = 0
            publish()
        }
    }

    private func advertise(port: UInt16) async {
        state.listenPort = port
        publish()
        try? await server.send(frame: ServerMessages.setListenPort(UInt32(port)))
    }

    // MARK: - Searching

    public func search(_ query: String, timeout: TimeInterval = 20, wishlist: Bool = false) async {
        timeoutTask?.cancel()
        let ticket = UInt32.random(in: 1...UInt32.max)
        state.query = query
        state.ticket = ticket
        state.isSearching = true
        state.replies = []
        state.finished = false
        publish()
        do {
            try await server.send(frame: wishlist
                ? ServerMessages.wishlistSearch(ticket: ticket, query: query)
                : ServerMessages.fileSearch(ticket: ticket, query: query))
        } catch {
            state.isSearching = false
            state.finished = true
            publish()
            return
        }
        timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch { return }
            await self.finish()
        }
    }

    public func stop() async {
        timeoutTask?.cancel()
        await finish()
    }

    public func shutdown() async {
        await stop()
        await stopListening()
        eventTask?.cancel()
        eventTask = nil
        for task in peerTasks.values { task.cancel() }
        peerTasks = [:]
        for conn in peerConns.values { conn.cancel() }
        peerConns = [:]
    }

    private func finish() async {
        guard state.isSearching else { return }
        state.isSearching = false
        state.finished = true
        publish()
    }

    private func publish() {
        stateContinuation.yield(state)
    }

    // MARK: - Server events

    private func consumeEvents() async {
        let stream = await server.makeEventStream()
        for await event in stream {
            if Task.isCancelled { return }
            switch event {
            case .connectToPeer(let request):
                guard request.type == "P" else { continue }
                let id = UUID()
                peerTasks[id] = Task {
                    await self.dialIndirect(id: id, request: request)
                    await self.removePeer(id)
                }
            case .cannotConnect:
                break // we don't initiate indirect requests yet (transfer slice)
            default:
                break // chat/room events belong to ChatEngine
            }
        }
    }

    private func removePeer(_ id: UUID) async {
        peerTasks[id] = nil
        peerConns[id] = nil
    }

    // MARK: - Peer connections

    private func dialIndirect(id: UUID, request: ConnectToPeerRequest) async {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: request.port)) else {
            await reportCannotConnect(request)
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(request.ip), port: port, using: .tcp)
        peerConns[id] = conn
        guard await waitReady(conn) else {
            conn.cancel()
            await reportCannotConnect(request)
            return
        }
        do {
            try await send(on: conn, data: PeerInitMessages.pierceFirewall(ticket: request.ticket))
            await readPeerFrames(conn)
        } catch {
            await reportCannotConnect(request)
        }
        conn.cancel()
    }

    private func handleDirect(_ conn: NWConnection) async {
        guard await waitReady(conn) else { conn.cancel(); return }
        var initial = Data()
        var parsed: (code: UInt8, payload: Data, consumed: Int)?
        while parsed == nil {
            guard let chunk = await receiveChunk(conn) else { conn.cancel(); return }
            initial.append(chunk)
            parsed = try? PeerInitMessages.parseInitFrame(initial)
        }
        guard let initFrame = parsed, initFrame.code == 1 else { conn.cancel(); return }
        var r = MessageReader(initFrame.payload)
        guard (try? r.string()) != nil, let type = try? r.string() else {
            conn.cancel()
            return
        }
        let pending = Data(initial.dropFirst(initFrame.consumed))
        if type == "F" {
            await onFileConnection?(PeerLink(conn), pending)
            return
        }
        guard type == "P" else { conn.cancel(); return }
        await readPeerFrames(conn, pending: pending)
        conn.cancel()
    }

    private func readPeerFrames(_ conn: NWConnection, pending: Data = Data()) async {
        var reader = FrameReader()
        reader.append(pending)
        while !Task.isCancelled {
            while let frame = try? reader.next() {
                await handlePeerFrame(frame)
            }
            guard let chunk = await receiveChunk(conn) else { return }
            reader.append(chunk)
        }
    }

    private func handlePeerFrame(_ frame: Frame) async {
        guard frame.code == 9 else { return }
        guard let reply = try? SearchReply(payload: frame.payload) else { return }
        guard state.isSearching, reply.ticket == state.ticket else { return }
        guard !state.replies.contains(where: { $0.username == reply.username }) else { return }
        state.replies.append(reply)
        publish()
    }

    private func reportCannotConnect(_ request: ConnectToPeerRequest) async {
        try? await server.send(frame: ServerMessages.cannotConnect(ticket: request.ticket, username: request.username))
    }

    // MARK: - NWConnection helpers

    private func waitReady(_ conn: NWConnection) async -> Bool {
        await withCheckedContinuation { cont in
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.fire { cont.resume(returning: true) }
                case .failed, .cancelled:
                    once.fire { cont.resume(returning: false) }
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue(label: "slsk.peer.dial"))
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                once.fire { cont.resume(returning: false) }
            }
        }
    }

    private func send(on conn: NWConnection, data: Data) async throws {
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

    private func receiveChunk(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if error != nil || data == nil || data!.isEmpty {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: data)
                }
            }
        }
    }
}