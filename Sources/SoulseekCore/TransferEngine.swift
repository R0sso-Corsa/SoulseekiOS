import Foundation
import Network
import SoulseekProtocol

/// Download engine: QueueDownload over P, TransferRequest/Reply handshake,
/// indirect F (ConnectToPeer → dial → PierceFw → ticket/offset → raw bytes)
/// or direct F handed off from the shared listener. `.partial` files + resume.
public actor TransferEngine {
    public enum TransferState: Equatable, Sendable {
        case queued
        case connecting
        case waiting(place: UInt32?)
        case downloading
        case completed
        case failed(String)
        case cancelled
    }

    public struct Transfer: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let username: String
        public let filename: String
        public let size: UInt64
        public var state: TransferState = .queued
        public var received: UInt64 = 0
        public var localPath: String?
        public var ticket: UInt32?
    }

    public private(set) var transfers: [Transfer] = []
    public nonisolated let updates: AsyncStream<[Transfer]>
    private let updatesContinuation: AsyncStream<[Transfer]>.Continuation

    private let server: ServerConnection
    private let directory: URL
    private var eventTask: Task<Void, Never>?
    private var pConns: [UUID: NWConnection] = [:]
    private var fConns: [UUID: NWConnection] = [:]
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private var fWaitTasks: [UUID: Task<Void, Never>] = [:]
    private var lastPublish: [UUID: Date] = [:]

    public init(server: ServerConnection, directory: URL) {
        self.server = server
        self.directory = directory
        var cont: AsyncStream<[Transfer]>.Continuation?
        updates = AsyncStream { cont = $0 }
        updatesContinuation = cont!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        eventTask = Task { await self.consumeFileEvents() }
    }

    deinit {
        updatesContinuation.finish()
    }

    // MARK: - Public API

    public func download(username: String, filename: String, size: UInt64) async {
        let t = Transfer(id: UUID(), username: username, filename: filename, size: size)
        transfers.append(t)
        publish()
        startRun(t.id)
    }

    public func retry(_ id: UUID) async {
        guard let t = transfer(id), t.state != .downloading else { return }
        update(id, force: true) { $0.state = .queued; $0.ticket = nil }
        startRun(id)
    }

    public func cancel(_ id: UUID) async {
        guard transfer(id) != nil else { return }
        update(id, force: true) { $0.state = .cancelled }
        teardownConns(id)
    }

    public func clearCompleted() async {
        transfers.removeAll { $0.state == .completed }
        publish()
    }

    public func requestQueuePlace(_ id: UUID) async {
        guard let t = transfer(id), let conn = pConns[id] else { return }
        try? await nwSend(conn, data: PeerMessages.placeInQueueRequest(filename: t.filename))
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        for id in Array(runTasks.keys) { teardownConns(id) }
    }

    /// Direct F connection handed off from the shared listener (reachable networks).
    public func handleDirectFile(_ link: PeerLink, pending: Data) async {
        let conn = link.connection
        var buf = pending
        while buf.count < 4 {
            guard let chunk = await nwReceiveChunk(conn) else { conn.cancel(); return }
            buf.append(chunk)
        }
        var ticketReader = MessageReader(buf.prefix(4))
        guard let ticket = try? ticketReader.u32(),
              let t = transfers.first(where: { $0.ticket == ticket && isPendingF($0.state) })
        else { conn.cancel(); return }
        fConns[t.id] = conn
        fWaitTasks[t.id]?.cancel()
        fWaitTasks[t.id] = nil
        await streamFile(conn: conn, id: t.id, pending: Data(buf.dropFirst(4)))
    }

    // MARK: - Download run

    private func startRun(_ id: UUID) {
        runTasks[id]?.cancel()
        runTasks[id] = Task { await self.runDownload(id) }
    }

    private func runDownload(_ id: UUID) async {
        guard let t = transfer(id) else { return }
        update(id, force: true) { $0.state = .connecting }
        do {
            let addr = try await server.peerAddress(for: t.username)
            guard addr.isOnline else { fail(id, "user is offline"); return }
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: addr.port)) else {
                fail(id, "invalid peer port"); return
            }
            let conn = NWConnection(host: NWEndpoint.Host(addr.ip), port: port, using: .tcp)
            pConns[id] = conn
            guard await nwWaitReady(conn) else {
                conn.cancel()
                fail(id, "cannot connect to user (firewalled?)")
                return
            }
            let me = await server.username
            try await nwSend(conn, data: PeerInitMessages.peerInit(username: me, type: "P"))
            try await nwSend(conn, data: PeerMessages.queueDownload(filename: t.filename))
            update(id, force: true) { $0.state = .waiting(place: nil) }
            await readPeerFrames(conn, id: id)
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    private func readPeerFrames(_ conn: NWConnection, id: UUID) async {
        var reader = FrameReader()
        while !Task.isCancelled {
            while let frame = try? reader.next() {
                await handlePeerFrame(frame, conn: conn, id: id)
            }
            guard let chunk = await nwReceiveChunk(conn) else { return }
            reader.append(chunk)
        }
    }

    private func handlePeerFrame(_ frame: Frame, conn: NWConnection, id: UUID) async {
        guard let t = transfer(id) else { return }
        switch frame.code {
        case 40: // TransferRequest — uploader offers the file
            guard let req = try? TransferRequest(payload: frame.payload),
                  req.direction == 1, req.filename == t.filename else { return }
            update(id, force: true) { $0.ticket = req.ticket; $0.state = .waiting(place: nil) }
            try? await nwSend(conn, data: PeerMessages.transferReply(ticket: req.ticket, allowed: true, filesize: t.size))
            // F connection should follow (indirect via server, or direct to our listener).
            fWaitTasks[id]?.cancel()
            fWaitTasks[id] = Task {
                do {
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                } catch {
                    return // cancelled: F connection arrived (or transfer torn down)
                }
                await self.fWaitTimedOut(id)
            }
        case 44: // PlaceInQueueReply
            if let reply = try? PlaceInQueueReply(payload: frame.payload), reply.filename == t.filename {
                update(id, force: true) { $0.state = .waiting(place: reply.place) }
            }
        case 46: // UploadFailed
            fail(id, "uploader reported failure")
        case 50: // TransferQueueFailed
            if let failed = try? TransferQueueFailed(payload: frame.payload), failed.filename == t.filename {
                fail(id, failed.reason)
            }
        default:
            break
        }
    }

    private func fWaitTimedOut(_ id: UUID) async {
        guard let t = transfer(id), isPendingF(t.state) else { return }
        fail(id, "no transfer connection (both peers firewalled?)")
    }

    // MARK: - Indirect F

    private func consumeFileEvents() async {
        for await request in server.fileEvents {
            if Task.isCancelled { return }
            Task { await self.dialIndirectF(request) }
        }
    }

    private func dialIndirectF(_ request: ConnectToPeerRequest) async {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: request.port)) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(request.ip), port: port, using: .tcp)
        guard await nwWaitReady(conn) else {
            conn.cancel()
            try? await server.send(frame: ServerMessages.cannotConnect(ticket: request.ticket, username: request.username))
            return
        }
        do {
            try await nwSend(conn, data: PeerInitMessages.pierceFirewall(ticket: request.ticket))
            guard let ticketData = await nwReceiveChunk(conn), ticketData.count >= 4 else { conn.cancel(); return }
            var ticketReader = MessageReader(ticketData.prefix(4))
            guard let ticket = try? ticketReader.u32(),
                  let t = transfers.first(where: { $0.ticket == ticket && isPendingF($0.state) })
            else { conn.cancel(); return }
            fConns[t.id] = conn
            fWaitTasks[t.id]?.cancel()
            fWaitTasks[t.id] = nil
            await streamFile(conn: conn, id: t.id, pending: Data(ticketData.dropFirst(4)))
        } catch {
            conn.cancel()
        }
    }

    // MARK: - File streaming

    private func streamFile(conn: NWConnection, id: UUID, pending: Data = Data()) async {
        guard let t = transfer(id) else { conn.cancel(); return }
        let partialURL = partialURL(for: t.filename)
        let finalURL = finalURL(for: t.filename)

        var offset: UInt64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
           let existing = attrs[.size] as? UInt64, existing < t.size {
            offset = existing
        }
        var w = MessageWriter()
        w.u64(offset)
        do {
            try await nwSend(conn, data: Data(w.bytes))
        } catch {
            fail(id, "offset send failed")
            conn.cancel()
            return
        }
        update(id, force: true) { $0.state = .downloading; $0.received = offset }

        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: partialURL) else {
            fail(id, "cannot open partial file")
            conn.cancel()
            return
        }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch {
            fail(id, "seek failed")
            conn.cancel()
            return
        }

        var received = offset
        var buffer = pending
        while received < t.size {
            if Task.isCancelled || transfer(id)?.state == .cancelled { conn.cancel(); return }
            if buffer.isEmpty {
                guard let chunk = await nwReceiveChunk(conn) else {
                    // Uploader closed early — keep the partial for resume.
                    fail(id, "incomplete (\(received)/\(t.size) bytes) — retry to resume")
                    conn.cancel()
                    return
                }
                buffer = chunk
            }
            let remaining = t.size - received
            let toWrite = buffer.prefix(Int(min(UInt64(buffer.count), remaining)))
            do { try handle.write(contentsOf: toWrite) } catch {
                fail(id, "write failed")
                conn.cancel()
                return
            }
            received += UInt64(toWrite.count)
            buffer = Data(buffer.dropFirst(toWrite.count))
            update(id) { $0.received = received }
        }

        // Complete: the DOWNLOADER closes, then finalize the file.
        conn.cancel()
        fConns[id] = nil
        do {
            try handle.close()
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            update(id, force: true) { $0.state = .completed; $0.localPath = finalURL.path; $0.received = t.size }
        } catch {
            fail(id, "finalize failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func isPendingF(_ state: TransferState) -> Bool {
        if case .waiting = state { return true }
        return false
    }

    private func transfer(_ id: UUID) -> Transfer? {
        transfers.first { $0.id == id }
    }

    private func update(_ id: UUID, force: Bool = false, _ mutate: (inout Transfer) -> Void) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transfers[idx])
        let now = Date()
        if force || now.timeIntervalSince(lastPublish[id] ?? .distantPast) >= 0.25 {
            lastPublish[id] = now
            publish()
        }
    }

    private func fail(_ id: UUID, _ reason: String) {
        update(id, force: true) { $0.state = .failed(reason) }
        teardownConns(id)
    }

    private func teardownConns(_ id: UUID) {
        runTasks[id]?.cancel()
        runTasks[id] = nil
        fWaitTasks[id]?.cancel()
        fWaitTasks[id] = nil
        pConns[id]?.cancel()
        pConns[id] = nil
        fConns[id]?.cancel()
        fConns[id] = nil
    }

    private func publish() {
        updatesContinuation.yield(transfers)
    }

    private func sanitized(_ filename: String) -> String {
        filename.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    private func partialURL(for filename: String) -> URL {
        directory.appendingPathComponent(sanitized(filename) + ".partial")
    }

    private func finalURL(for filename: String) -> URL {
        directory.appendingPathComponent(sanitized(filename))
    }
}