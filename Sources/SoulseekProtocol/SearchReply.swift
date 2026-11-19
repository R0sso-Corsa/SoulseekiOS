import Foundation

/// One file in a search reply. Paths are Windows-style (backslashes);
/// folder grouping is client-side. Attribute keys per the docs:
/// 0 bitrate, 1 duration(s), 2 VBR, 4 sample rate, 5 bitness.
public struct FileEntry: Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let ext: String
    public let bitrate: UInt32?
    public let duration: UInt32?
    public let vbr: Bool?
    public let sampleRate: UInt32?
    public let bitness: UInt32?

    public var filename: String {
        if let i = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            return String(path[path.index(after: i)...])
        }
        return path
    }

    public var folder: String {
        if let i = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            return String(path[..<i])
        }
        return ""
    }

    init(reader r: inout MessageReader) throws {
        _ = try r.u8() // code, always 1
        path = try r.string()
        size = try r.u64()
        let rawExt = try r.string()
        let attrCount = try r.u32()
        guard attrCount <= 1024 else { throw CodecError.truncated }
        var attrs: [UInt32: UInt32] = [:]
        for _ in 0..<attrCount {
            let key = try r.u32()
            attrs[key] = try r.u32()
        }
        if rawExt.isEmpty {
            // SoulseekQt sends blank extensions; derive from the filename.
            let name: String
            if let i = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
                name = String(path[path.index(after: i)...])
            } else {
                name = path
            }
            if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                ext = String(name[name.index(after: dot)...]).lowercased()
            } else {
                ext = ""
            }
        } else {
            ext = rawExt.lowercased()
        }
        bitrate = attrs[0]
        duration = attrs[1]
        vbr = attrs[2].map { $0 != 0 }
        sampleRate = attrs[4]
        bitness = attrs[5]
    }
}

/// PeerSearchReply (peer code 9). The ENTIRE payload is zlib-compressed
/// (verified against both aioslsk and Nicotine+ docs). Decompressed order:
/// username, ticket, results array, slots free, avg speed, queue size,
/// then optional unknown + locked results (ignored).
public struct SearchReply: Equatable, Sendable {
    public let username: String
    public let ticket: UInt32
    public let files: [FileEntry]
    public let freeSlots: Bool
    public let avgSpeed: UInt32
    public let queueSize: UInt32

    public init(payload: Data) throws {
        let raw = try Zlib.inflate(payload)
        var r = MessageReader(raw)
        username = try r.string()
        ticket = try r.u32()
        let count = try r.u32()
        guard count <= 100_000 else { throw CodecError.truncated }
        var files: [FileEntry] = []
        files.reserveCapacity(Int(min(count, 10_000)))
        for _ in 0..<count {
            files.append(try FileEntry(reader: &r))
        }
        self.files = files
        freeSlots = try r.u8() != 0
        avgSpeed = try r.u32()
        queueSize = try r.u32()
    }
}

/// ConnectToPeer (server code 18) as RECEIVED from the server: a peer wants
/// an indirect connection — dial the given address and send PierceFw(ticket).
public struct ConnectToPeerRequest: Equatable, Sendable {
    public let username: String
    public let type: String
    public let ip: String
    public let port: UInt32
    public let ticket: UInt32
    public let privileged: Bool
    public let obfuscatedPort: UInt32?

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        username = try r.string()
        type = try r.string()
        ip = try r.ipaddr()
        port = try r.u32()
        ticket = try r.u32()
        privileged = try r.u8() != 0
        if r.remaining >= 8 {
            _ = try r.u32() // obfuscated_port_amount
            obfuscatedPort = try r.u32()
        } else {
            obfuscatedPort = nil
        }
    }
}