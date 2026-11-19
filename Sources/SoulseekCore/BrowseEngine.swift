import Foundation
import Network

import SoulseekProtocol

/// Browse a user's shared folders: direct P (GetPeerAddress → dial →
/// PeerInit(P) → GetShareFileList(4) → SharedFileList(5)), with an indirect
/// fallback for firewalled targets (ConnectToPeer(P) → they dial our listener
/// with PierceFw(ticket) → handleIndirectBrowse).
public actor BrowseEngine {
    public enum BrowseError: Error, Equatable, LocalizedError {
        case offline, firewalled, connectionClosed, timeout

        public var errorDescription: String? {
            switch self {
            case .offline: return "User is offline"
            case .firewalled: return "User is unreachable (both firewalled?)"
            case .connectionClosed: return "Connection closed during browse"
            case .timeout: return "Browse timed out"
            }
        }
    }

    private let server: ServerConnection
    private var pending: [UInt32: CheckedContinuation<[SharedFolder], Error>] = [:]
    private var waitTasks: [UInt32: Task<Void, Never>] = [:]
    private var eventTask: Task<Void, Never>?

    public init(server: ServerConnection) {
        self.server = server
        eventTask = Task { await self.consumeEvents() }
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        for ticket in Array(waitTasks.keys) { fail(ticket, .timeout) }
    }

    public func browse(username: String) async throws -> [SharedFolder] {
        let addr = try await server.peerAddress(for: username)
        guard addr.isOnline else { throw BrowseError.offline }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: addr.port)) else {
            return try await indirectBrowse(username: username)
        }
        let conn = NWConnection(host: NWEndpoint.Host(addr.ip), port: port, using: .tcp)
        guard await nwWaitReady(conn) else {
            conn.cancel()
            // Firewalled sharer: ask the server to make them dial us.
            return try await indirectBrowse(username: username)
        }
        defer { conn.cancel() }
        let me = await server.username
        try await nwSend(conn, data: PeerInitMessages.peerInit(username: me, type: "P"))
        try await nwSend(conn, data: PeerMessages.sharedFileListRequest())
        return try await readFolders(conn)
    }

    /// Inbound PierceFw matching a pending indirect browse. Returns false
    /// when the ticket isn't ours (the router tries the next engine).
    public func handleIndirectBrowse(_ link: PeerLink, ticket: UInt32) async -> Bool {
        guard pending[ticket] != nil else { return false }
        waitTasks[ticket]?.cancel()
        waitTasks[ticket] = nil
        let conn = link.connection
        do {
            try await nwSend(conn, data: PeerMessages.sharedFileListRequest())
            let folders = try await readFolders(conn)
            resolve(ticket, folders)
        } catch {
            fail(ticket, error as? BrowseError ?? .connectionClosed)
        }
        conn.cancel()
        return true
    }

    // MARK: - Indirect request

    private func indirectBrowse(username: String) async throws -> [SharedFolder] {
        let ticket = UInt32.random(in: 1...UInt32.max)
        return try await withCheckedThrowingContinuation { cont in
            pending[ticket] = cont
            Task {
                var w = MessageWriter()
                w.u32(ticket)
                w.string(username)
                w.string("P")
                try? await server.send(frame: w.frame(code: 18))
            }
            waitTasks[ticket] = Task {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                await self.fail(ticket, .firewalled)
            }
        }
    }

    private func consumeEvents() async {
        let stream = await server.makeEventStream()
        for await event in stream {
            if Task.isCancelled { return }
            if case .cannotConnect(let ticket) = event, pending[ticket] != nil {
                fail(ticket, .firewalled)
            }
        }
    }

    private func resolve(_ ticket: UInt32, _ folders: [SharedFolder]) {
        waitTasks[ticket]?.cancel()
        waitTasks[ticket] = nil
        if let cont = pending.removeValue(forKey: ticket) {
            cont.resume(returning: folders)
        }
    }

    private func fail(_ ticket: UInt32, _ error: BrowseError) {
        waitTasks[ticket]?.cancel()
        waitTasks[ticket] = nil
        if let cont = pending.removeValue(forKey: ticket) {
            cont.resume(throwing: error)
        }
    }

    // MARK: - Shared

    private func readFolders(_ conn: NWConnection) async throws -> [SharedFolder] {
        var reader = FrameReader()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            // Bounded receive: a silent peer must not hang the browse forever.
            guard let chunk = await nwReceiveChunk(conn, timeout: 30_000_000_000) else {
                throw BrowseError.connectionClosed
            }
            reader.append(chunk)
            while let frame = try reader.next() {
                if frame.code == 5 {
                    return try SharedFileList(payload: frame.payload).folders
                }
            }
        }
        throw BrowseError.timeout
    }
}