import Foundation
import Network

import SoulseekProtocol

/// Browse a user's shared folders over a direct P connection:
/// GetPeerAddress → dial → PeerInit(P) → GetShareFileList(4) →
/// SharedFileList(5). Indirect browse (firewalled targets) is a follow-up.
public actor BrowseEngine {
    public enum BrowseError: Error, Equatable, LocalizedError {
        case offline, firewalled, connectionClosed, timeout

        public var errorDescription: String? {
            switch self {
            case .offline: return "User is offline"
            case .firewalled: return "User is firewalled — direct browse unavailable"
            case .connectionClosed: return "Connection closed during browse"
            case .timeout: return "Browse timed out"
            }
        }
    }

    private let server: ServerConnection

    public init(server: ServerConnection) {
        self.server = server
    }

    public func browse(username: String) async throws -> [SharedFolder] {
        let addr = try await server.peerAddress(for: username)
        guard addr.isOnline else { throw BrowseError.offline }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: addr.port)) else {
            throw BrowseError.firewalled
        }
        let conn = NWConnection(host: NWEndpoint.Host(addr.ip), port: port, using: .tcp)
        guard await nwWaitReady(conn) else {
            conn.cancel()
            throw BrowseError.firewalled
        }
        defer { conn.cancel() }
        let me = await server.username
        try await nwSend(conn, data: PeerInitMessages.peerInit(username: me, type: "P"))
        try await nwSend(conn, data: PeerMessages.sharedFileListRequest())

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