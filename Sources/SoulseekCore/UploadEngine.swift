import Foundation
import Network
import SoulseekProtocol

/// Upload engine (sharing): serves QueueDownload requests from our ShareIndex.
/// Flow: QueueDownload(43) in on P → slot/queue → TransferRequest(40, dir 0) →
/// TransferReply(41) → F out (direct dial, or ConnectToPeer(F) so the
/// downloader dials us — works behind NAT) → ticket → offset → stream bytes.
public actor UploadEngine {
    public enum UploadState: Equatable, Sendable {
        case queued, connecting, transferring, completed, failed(String), cancelled
    }

    public struct Upload: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let username: String
        public let filename: String
        public let size: UInt64
        public var state: UploadState = .queued
        public var sent: UInt64 = 0
        public var ticket: UInt32 = 0
    }

    public private(set) var uploads: [Upload] = []
    public var slots: Int = 2
    public nonisolated let updates: AsyncStream<[Upload]>
    private let updatesContinuation: AsyncStream<[Upload]>.Continuation

    private let server: ServerConnection
    private let index: ShareIndex
    private var pConns: [UUID: PeerLink] = [:]
    private var fConns: [UUID: PeerLink] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pendingF: [UInt32: UUID] = [:]
    private var fWaitTasks: [UUID: Task<Void, Never>] = [:]
    private var lastPublish: [UUID: Date] = [:]
    private var startedAt: [UUID: Date] = [:]

    public init(server: ServerConnection, index: ShareIndex) {
        self.server = server
        self.index = index
        var cont: AsyncStream<[Upload]>.Continuation?
        updates = AsyncStream { cont = $0 }
        updatesContinuation = cont!
    }

    deinit {
        updatesContinuation.finish()
    }

    public func shutdown() async {
        for id in Array(tasks.keys) { teardown(id) }
    }

    // MARK: - Request entry (routed from SearchEngine)

    /// QueueDownload(43) arrived on a P connection owned by the downloader.
    public func handleQueueDownload(_ link: PeerLink, username: String, filename: String, pending: Data) async {
        guard let file = await index.file(for: filename) else {
            try? await nwSend(link.connection, data: PeerMessages.queueFailed(filename: filename, reason: "File not shared."))
            link.connection.cancel()
            return
        }
        var u = Upload(id: UUID(), username: username, filename: filename, size: file.size)
        u.ticket = UInt32.random(in: 1...UInt32.max)
        uploads.append(u)
        publish()
        pConns[u.id] = link
        tasks[u.id] = Task { await self.serveUpload(u.id, pending: pending) }
    }

    /// Inbound F connection with PierceFw(ticket) — the downloader dialed us
    /// after our ConnectToPeer(F). We are the uploader on this connection.
    /// Returns false when the ticket isn't ours (router tries the next engine).
    public func handleIndirectUpload(_ link: PeerLink, ticket: UInt32, pending: Data) async -> Bool {
        guard let id = pendingF.removeValue(forKey: ticket), upload(id) != nil else {
            return false
        }
        fWaitTasks[id]?.cancel()
        fWaitTasks[id] = nil
        fConns[id] = link
        await streamOut(id, conn: link.connection, pending: pending)
        return true
    }

    public func cancel(_ id: UUID) async {
        guard upload(id) != nil else { return }
        update(id, force: true) { $0.state = .cancelled }
        teardown(id)
    }

    public func clearCompleted() async {
        uploads.removeAll { $0.state == .completed }
        publish()
    }

    // MARK: - Serve flow

    private func serveUpload(_ id: UUID, pending: Data) async {
        guard let u = upload(id), let link = pConns[id] else { return }
        // Wait for a free slot; keep the downloader informed of their place.
        while activeCount() >= slots {
            if Task.isCancelled || upload(id)?.state == .cancelled { return }
            let place = uploads.filter { $0.state == .queued && $0.id != id }.count + 1
            try? await nwSend(link.connection, data: PeerMessages.placeInQueueReply(filename: u.filename, place: UInt32(place)))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if Task.isCancelled || upload(id)?.state == .cancelled { return }
        update(id, force: true) { $0.state = .connecting }

        do {
            try await nwSend(link.connection, data: PeerMessages.transferRequest(direction: 0, ticket: u.ticket, filename: u.filename, filesize: u.size))
        } catch {
            fail(id, "transfer request send failed")
            return
        }

        // Await TransferReply(41) on the P connection.
        var reader = FrameReader()
        reader.append(pending)
        var allowed: Bool?
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline && allowed == nil {
            while let frame = try? reader.next() {
                if frame.code == 41 {
                    var r = MessageReader(frame.payload)
                    if (try? r.u32()) == u.ticket {
                        allowed = ((try? r.u8()) ?? 0) != 0
                    }
                } else if frame.code == 51 {
                    try? await nwSend(link.connection, data: PeerMessages.placeInQueueReply(filename: u.filename, place: 0))
                }
            }
            if allowed != nil { break }
            guard let chunk = await nwReceiveChunk(link.connection, timeout: 5_000_000_000) else { break }
            reader.append(chunk)
        }
        guard allowed == true else {
            fail(id, allowed == false ? "downloader declined" : "no transfer reply")
            return
        }

        // F phase: try a direct dial to the downloader first.
        var direct: NWConnection?
        if let addr = try? await server.peerAddress(for: u.username),
           addr.isOnline,
           let port = NWEndpoint.Port(rawValue: UInt16(clamping: addr.port)) {
            let c = NWConnection(host: NWEndpoint.Host(addr.ip), port: port, using: .tcp)
            if await nwWaitReady(c, timeout: 8_000_000_000) {
                direct = c
            } else {
                c.cancel()
            }
        }
        if let c = direct {
            fConns[id] = PeerLink(c)
            await streamOut(id, conn: c, pending: Data())
        } else {
            // Indirect: ask the server to make the downloader dial our listener.
            pendingF[u.ticket] = id
            var w = MessageWriter()
            w.u32(u.ticket)
            w.string(u.username)
            w.string("F")
            try? await server.send(frame: w.frame(code: 18))
            fWaitTasks[id] = Task {
                do {
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                } catch { return }
                await self.fWaitTimedOut(id)
            }
        }
    }

    private func streamOut(_ id: UUID, conn: NWConnection, pending: Data) async {
        guard let u = upload(id), let file = await index.file(for: u.filename) else {
            fail(id, "file vanished from share")
            return
        }
        // Uploader speaks first on F: ticket(u32), then the downloader's offset(u64).
        var ticketBytes = MessageWriter()
        ticketBytes.u32(u.ticket)
        do {
            try await nwSend(conn, data: Data(ticketBytes.bytes))
        } catch {
            fail(id, "ticket send failed")
            conn.cancel()
            return
        }
        var buf = pending
        while buf.count < 8 {
            guard let chunk = await nwReceiveChunk(conn, timeout: 30_000_000_000) else {
                fail(id, "no offset received")
                conn.cancel()
                return
            }
            buf.append(chunk)
        }
        var or = MessageReader(buf.prefix(8))
        let offset = (try? or.u64()) ?? 0
        guard offset <= u.size else {
            fail(id, "invalid resume offset")
            conn.cancel()
            return
        }
        guard let handle = FileHandle(forReadingAtPath: file.localPath) else {
            fail(id, "cannot open shared file")
            conn.cancel()
            return
        }
        defer {
            try? handle.close()
            conn.cancel()
        }
        do { try handle.seek(toOffset: offset) } catch {
            fail(id, "seek failed")
            return
        }
        update(id, force: true) { $0.state = .transferring; $0.sent = offset }
        startedAt[id] = Date()
        var sent = offset
        while sent < u.size {
            if Task.isCancelled || upload(id)?.state == .cancelled { return }
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty {
                fail(id, "shared file changed on disk")
                return
            }
            do {
                try await nwSend(conn, data: chunk)
            } catch {
                fail(id, "send failed at \(sent)/\(u.size)")
                return
            }
            sent += UInt64(chunk.count)
            update(id) { $0.sent = sent }
        }
        update(id, force: true) { $0.state = .completed; $0.sent = u.size }
        let dt = Date().timeIntervalSince(startedAt[id] ?? Date())
        if dt > 0.01 {
            try? await server.send(frame: ServerMessages.sendUploadSpeed(UInt32(min(Double(u.size - offset) / dt, Double(UInt32.max)))))
        }
        // Downloader closes when complete; give it a moment, then tear down.
        _ = await nwReceiveChunk(conn, timeout: 5_000_000_000)
        teardown(id)
    }

    private func fWaitTimedOut(_ id: UUID) async {
        guard let u = upload(id), u.state == .connecting else { return }
        pendingF[u.ticket] = nil
        fail(id, "downloader never connected (both firewalled?)")
    }

    // MARK: - State helpers

    private func upload(_ id: UUID) -> Upload? {
        uploads.first { $0.id == id }
    }

    private func activeCount() -> Int {
        uploads.filter { $0.state == .connecting || $0.state == .transferring }.count
    }

    private func update(_ id: UUID, force: Bool = false, _ mutate: (inout Upload) -> Void) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        mutate(&uploads[i])
        let now = Date()
        if force || now.timeIntervalSince(lastPublish[id] ?? .distantPast) >= 0.25 {
            lastPublish[id] = now
            publish()
        }
    }

    private func fail(_ id: UUID, _ reason: String) {
        update(id, force: true) { $0.state = .failed(reason) }
        teardown(id)
    }

    private func teardown(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        fWaitTasks[id]?.cancel()
        fWaitTasks[id] = nil
        pConns[id]?.connection.cancel()
        pConns[id] = nil
        fConns[id]?.connection.cancel()
        fConns[id] = nil
        if let u = upload(id) { pendingF[u.ticket] = nil }
    }

    private func publish() {
        updatesContinuation.yield(uploads)
    }
}