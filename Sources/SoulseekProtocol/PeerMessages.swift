import Foundation

/// Peer (P/F) message encoders. Layouts doc-verified 2026-11-18.
public enum PeerMessages {
    /// Code 43. Ask the uploader to queue a file for us.
    public static func queueDownload(filename: String) -> Data {
        var w = MessageWriter()
        w.string(filename)
        return w.frame(code: 43)
    }

    /// Code 40. direction: 0 = upload, 1 = download. filesize optional for downloads.
    public static func transferRequest(direction: UInt32, ticket: UInt32, filename: String, filesize: UInt64?) -> Data {
        var w = MessageWriter()
        w.u32(direction)
        w.u32(ticket)
        w.string(filename)
        if let filesize { w.u64(filesize) }
        return w.frame(code: 40)
    }

    /// Code 41. allowed → optional filesize; denied → optional reason.
    public static func transferReply(ticket: UInt32, allowed: Bool, filesize: UInt64? = nil, reason: String? = nil) -> Data {
        var w = MessageWriter()
        w.u32(ticket)
        w.u8(allowed ? 1 : 0)
        if allowed {
            if let filesize { w.u64(filesize) }
        } else if let reason {
            w.string(reason)
        }
        return w.frame(code: 41)
    }

    /// Code 51. Ask for our place in the uploader's queue.
    public static func placeInQueueRequest(filename: String) -> Data {
        var w = MessageWriter()
        w.string(filename)
        return w.frame(code: 51)
    }

    /// Code 15. No parameters.
    public static func userInfoRequest() -> Data {
        MessageWriter().frame(code: 15)
    }

    /// Code 4. Ask a peer for their shared file list (empty payload).
    public static func sharedFileListRequest() -> Data {
        MessageWriter().frame(code: 4)
    }
}

/// PeerTransferRequest (40) received from an uploader when a slot frees.
public struct TransferRequest: Equatable, Sendable {
    public let direction: UInt32
    public let ticket: UInt32
    public let filename: String
    public let filesize: UInt64?

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        direction = try r.u32()
        ticket = try r.u32()
        filename = try r.string()
        filesize = r.remaining >= 8 ? try r.u64() : nil
    }
}

/// PeerPlaceInQueueReply (44).
public struct PlaceInQueueReply: Equatable, Sendable {
    public let filename: String
    public let place: UInt32

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        filename = try r.string()
        place = try r.u32()
    }
}

/// PeerTransferQueueFailed (50).
public struct TransferQueueFailed: Equatable, Sendable {
    public let filename: String
    public let reason: String

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        filename = try r.string()
        reason = try r.string()
    }
}

/// GetPeerAddress (3) reply. ip 0.0.0.0 / port 0 = peer offline.
/// Note: obfuscated_port is u16 here (u32 in SetListenPort).
public struct PeerAddressReply: Equatable, Sendable {
    public let username: String
    public let ip: String
    public let port: UInt32
    public let obfuscatedPort: UInt16?

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        username = try r.string()
        ip = try r.ipaddr()
        port = try r.u32()
        if r.remaining >= 6 {
            _ = try r.u32() // obfuscated_port_amount
            obfuscatedPort = try r.u16()
        } else {
            obfuscatedPort = nil
        }
    }

    public var isOnline: Bool { ip != "0.0.0.0" && port != 0 }
}