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
        case paused
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
        /// Chat-media attachment (AD-16) — lands in mediaDirectory, not the
        /// music Downloads folder.
        public var isMedia = false
    }

    public private(set) var transfers: [Transfer] = []
    public nonisolated let updates: AsyncStream<[Transfer]>
    private let updatesContinuation: AsyncStream<[Transfer]>.Continuation

    private let server: ServerConnection
    private let directory: URL
    private let mediaDirectory: URL?
    private var eventTask: Task<Void, Never>?
    private var serverEventTask: Task<Void, Never>?
    private var pConns: [UUID: NWConnection] = [:]
    private var fConns: [UUID: NWConnection] = [:]
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private var fWaitTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingP: [UInt32: UUID] = [:]
    private var pWaitTasks: [UUID: Task<Void, Never>] = [:]
    private var lastPublish: [UUID: Date] = [:]
    private var speedLimitKBs: UInt64 = 0

    /// Download throttle in KB/s; 0 = unlimited.
    public func setSpeedLimit(kbps: UInt64) {
        speedLimitKBs = kbps
    }

    public init(server: ServerConnection, directory: URL, mediaDirectory: URL? = nil) {
        self.server = server
        self.directory = directory
        self.mediaDirectory = mediaDirectory
        var cont: AsyncStream<[Transfer]>.Continuation?
        updates = AsyncStream { cont = $0 }
        updatesContinuation = cont!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let mediaDirectory {
            try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        }
        eventTask = Task { await self.consumeFileEvents() }
        serverEventTask = Task { await self.consumeServerEvents() }
    }

    /// CannotConnect for a pending indirect-P request → fail fast instead of
    /// waiting out the 60s timer (the peer tried to dial us and couldn't).
    private func consumeServerEvents() async {
        let stream = await server.makeEventStream()
        for await event in stream {
            if Task.isCancelled { return }
            if case .cannotConnect(let ticket) = event,
               let id = pendingP.removeValue(forKey: ticket) {
                pWaitTasks[id]?.cancel()
                pWaitTasks[id] = nil
                fail(id, "user unreachable (both firewalled?)")
            }
        }
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

    /// Chat-media fetch (AD-16): same transfer path, separate destination so
    /// pictures/videos never clutter the music Library.
    public func downloadMedia(username: String, filename: String, size: UInt64) async {
        var t = Transfer(id: UUID(), username: username, filename: filename, size: size)
        t.isMedia = true
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

    /// App backgrounded: stop active transfers cleanly, keeping .partial files
    /// and received counts so resumeAll can continue from the exact offset.
    public func pauseAll() async {
        for t in transfers {
            switch t.state {
            case .queued, .connecting, .waiting, .downloading:
                update(t.id, force: true) { $0.state = .paused }
                teardownConns(t.id)
            default:
                break
            }
        }
    }

    /// App foregrounded: re-queue everything paused (resumes from .partial).
    public func resumeAll() async {
        for t in transfers where t.state == .paused {
            await retry(t.id)
        }
    }

    public func requestQueuePlace(_ id: UUID) async {
        guard let t = transfer(id), let conn = pConns[id] else { return }
        try? await nwSend(conn, data: PeerMessages.placeInQueueRequest(filename: t.filename))
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        serverEventTask?.cancel()
        serverEventTask = nil
        for id in Array(runTasks.keys) { teardownConns(id) }
    }

    /// Direct P dial failed → ConnectToPeer(P) via the server; the uploader
    /// dials our listener and sends PierceFw(ticket) → handleIndirectP.
    private func requestIndirectP(_ id: UUID, username: String) async {
        guard let t = transfer(id) else { return }
        let ticket = UInt32.random(in: 1...UInt32.max)
        pendingP[ticket] = id
        update(id, force: true) { $0.state = .connecting }
        var w = MessageWriter()
        w.u32(ticket)
        w.string(username)
        w.string("P")
        try? await server.send(frame: w.frame(code: 18))
        pWaitTasks[id] = Task {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch { return }
            await self.pWaitTimedOut(id, ticket: ticket)
        }
    }

    private func pWaitTimedOut(_ id: UUID, ticket: UInt32) async {
        pendingP[ticket] = nil
        guard let t = transfer(id), t.state == .connecting else { return }
        fail(id, "user unreachable (both firewalled?)")
    }

    /// Inbound PierceFw on our listener matching a pending indirect-P request.
    /// Returns false when the ticket isn't ours (router tries the next engine).
    public func handleIndirectP(_ link: PeerLink, ticket: UInt32, pending: Data) async -> Bool {
        guard let id = pendingP.removeValue(forKey: ticket), let t = transfer(id) else { return false }
        pWaitTasks[id]?.cancel()
        pWaitTasks[id] = nil
        let conn = link.connection
        pConns[id] = conn
        do {
            try await nwSend(conn, data: PeerMessages.queueDownload(filename: t.filename))
        } catch {
            fail(id, "queue send failed")
            return true
        }
        update(id, force: true) { $0.state = .waiting(place: nil) }
        await readPeerFrames(conn, id: id)
        return true
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
        guard let t = transfer(id) else { return }
        // One active run per user: desktop uploaders drop competing
        // connections from the same peer, so album tracks wait their turn.
        if hasActiveRun(for: t.username, excluding: id) { return }
        // Claim synchronously so a same-tick sibling sees us as active.
        update(id, force: true) { $0.state = .connecting }
        launchRun(id)
    }

    private func launchRun(_ id: UUID) {
        runTasks[id]?.cancel()
        runTasks[id] = Task { await self.runDownload(id) }
    }

    private func isActiveState(_ s: TransferState) -> Bool {
        switch s {
        case .connecting, .downloading, .waiting: return true
        default: return false
        }
    }

    private func hasActiveRun(for username: String, excluding id: UUID) -> Bool {
        transfers.contains { $0.username == username && $0.id != id && isActiveState($0.state) }
    }

    /// A run finished — start the next queued transfer for the same user.
    private func startNextPending(for username: String) {
        guard !hasActiveRun(for: username, excluding: UUID()) else { return }
        if let next = transfers.first(where: { $0.username == username && $0.state == .queued }) {
            update(next.id, force: true) { $0.state = .connecting }
            launchRun(next.id)
        }
    }

    private func runDownload(_ id: UUID) async {
        guard let t = transfer(id), t.state == .queued || t.state == .connecting else { return }
        update(id, force: true) { $0.state = .connecting }
        do {
            let addr = try await server.peerAddress(for: t.username)
            // A pause/cancel may have landed while we awaited the address —
            // never resurrect a torn-down transfer (zombie run).
            if Task.isCancelled || transfer(id)?.state == .paused || transfer(id)?.state == .cancelled { return }
            guard addr.isOnline else { fail(id, "user is offline"); return }
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: addr.port)) else {
                fail(id, "invalid peer port"); return
            }
            let conn = NWConnection(host: NWEndpoint.Host(addr.ip), port: port, using: .tcp)
            pConns[id] = conn
            guard await nwWaitReady(conn) else {
                conn.cancel()
                pConns[id] = nil
                if Task.isCancelled || transfer(id)?.state == .paused || transfer(id)?.state == .cancelled { return }
                // Firewalled uploader: ask the server to make them dial us.
                await requestIndirectP(id, username: t.username)
                return
            }
            if Task.isCancelled || transfer(id)?.state == .paused || transfer(id)?.state == .cancelled { conn.cancel(); return }
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
        let partialURL = partialURL(for: t.filename, isMedia: t.isMedia)
        let finalURL = finalURL(for: t.filename, isMedia: t.isMedia)

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
        var windowStart = Date()
        var windowBytes: UInt64 = 0
        while received < t.size {
            if Task.isCancelled || transfer(id)?.state == .cancelled || transfer(id)?.state == .paused { conn.cancel(); return }
            if buffer.isEmpty {
                // 60s idle bound: a stalled uploader fails the transfer (the
                // .partial is kept, so retry resumes) instead of hanging it.
                guard let chunk = await nwReceiveChunk(conn, timeout: 60_000_000_000) else {
                    if Task.isCancelled || transfer(id)?.state == .paused || transfer(id)?.state == .cancelled { conn.cancel(); return }
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
            // Token-window throttle: sleep off any burst above the limit.
            if speedLimitKBs > 0 {
                windowBytes += UInt64(toWrite.count)
                let elapsed = Date().timeIntervalSince(windowStart)
                let rate = Double(speedLimitKBs * 1024)
                let allowed = rate * elapsed
                if Double(windowBytes) > allowed {
                    let sleepS = (Double(windowBytes) - allowed) / rate
                    try? await Task.sleep(nanoseconds: UInt64(sleepS * 1_000_000_000))
                }
                if elapsed >= 1 {
                    windowStart = Date()
                    windowBytes = 0
                }
            }
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
            if !t.isMedia {
                recordManifest(filename: t.filename, storedAs: finalURL.lastPathComponent)
            }
        } catch {
            fail(id, "finalize failed: \(error.localizedDescription)")
        }
    }

    /// Maps stored flat filenames → original Soulseek paths so the Library
    /// can group downloads by album. Hidden JSON sidecar in the download dir.
    private func recordManifest(filename: String, storedAs: String) {
        let url = directory.appendingPathComponent(".downloads-manifest.json")
        var map = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        map[storedAs] = filename
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: url, options: .atomic)
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
        let state = transfers[idx].state
        let username = transfers[idx].username
        switch state {
        case .completed, .failed, .cancelled:
            startNextPending(for: username)
        default:
            break
        }
    }

    private func fail(_ id: UUID, _ reason: String) {
        // Late failures from torn-down connections must not overwrite an
        // intentional pause/cancel.
        guard let t = transfer(id), t.state != .paused, t.state != .cancelled else { return }
        update(id, force: true) { $0.state = .failed(reason) }
        teardownConns(id)
    }

    private func teardownConns(_ id: UUID) {
        runTasks[id]?.cancel()
        runTasks[id] = nil
        fWaitTasks[id]?.cancel()
        fWaitTasks[id] = nil
        pWaitTasks[id]?.cancel()
        pWaitTasks[id] = nil
        if let t = transfer(id) { pendingP = pendingP.filter { $0.value != id } }
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

    private func partialURL(for filename: String, isMedia: Bool = false) -> URL {
        let base = (isMedia ? mediaDirectory : nil) ?? directory
        return base.appendingPathComponent(sanitized(filename) + ".partial")
    }

    private func finalURL(for filename: String, isMedia: Bool = false) -> URL {
        let base = (isMedia ? mediaDirectory : nil) ?? directory
        return base.appendingPathComponent(sanitized(filename))
    }
}