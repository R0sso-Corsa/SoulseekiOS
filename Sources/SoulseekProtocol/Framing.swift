import Foundation

/// One Soulseek message: `[u32 length][u32 code][payload]`.
/// `length` counts code + payload (excludes itself). All integers little-endian.
/// Spec: https://aioslsk.readthedocs.io/en/stable/MESSAGES.html
public struct Frame: Equatable {
    public let code: UInt32
    public let payload: Data

    public init(code: UInt32, payload: Data) {
        self.code = code
        self.payload = payload
    }
}

public enum CodecError: Error, Equatable {
    case truncated
    case frameTooLarge(UInt32)
    case invalidUTF8
}

/// Accumulates received bytes and yields complete frames.
public struct FrameReader {
    private var buffer: [UInt8] = []
    /// Sanity cap; share lists can be large but not unbounded.
    private let maxFrame: UInt32 = 32 * 1024 * 1024

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Next complete frame, or nil when more bytes are needed.
    public mutating func next() throws -> Frame? {
        guard buffer.count >= 8 else { return nil }
        let length = leU32(Array(buffer[0..<4]))
        guard length >= 4 else { throw CodecError.truncated }
        guard length <= maxFrame else { throw CodecError.frameTooLarge(length) }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let code = leU32(Array(buffer[4..<8]))
        let payload = Data(buffer[8..<total])
        buffer.removeFirst(total)
        return Frame(code: code, payload: payload)
    }
}

/// Builds a message payload, then frames it.
public struct MessageWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    public mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    /// u32 length + UTF-8 bytes.
    public mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        u32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    public func frame(code: UInt32) -> Data {
        var header = MessageWriter()
        header.u32(UInt32(bytes.count + 4))
        header.u32(code)
        return Data(header.bytes + bytes)
    }

    /// Peer-init framing: u8 code instead of u32.
    public func frame(initCode: UInt8) -> Data {
        var header = MessageWriter()
        header.u32(UInt32(bytes.count + 1))
        header.u8(initCode)
        return Data(header.bytes + bytes)
    }
}

/// Cursor over a frame payload.
public struct MessageReader {
    private let bytes: [UInt8]
    private var pos = 0

    public init(_ payload: Data) {
        bytes = Array(payload)
    }

    public var remaining: Int { bytes.count - pos }

    /// Consume and return all remaining bytes.
    public mutating func rest() -> Data {
        let r = Data(bytes[pos...])
        pos = bytes.count
        return r
    }

    private mutating func take(_ n: Int) throws -> [UInt8] {
        guard pos + n <= bytes.count else { throw CodecError.truncated }
        let out = Array(bytes[pos..<pos + n])
        pos += n
        return out
    }

    public mutating func u8() throws -> UInt8 { try take(1)[0] }

    public mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    public mutating func u32() throws -> UInt32 { leU32(try take(4)) }

    public mutating func u64() throws -> UInt64 {
        try take(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * $1.offset)) }
    }

    public mutating func string() throws -> String {
        let n = Int(try u32())
        guard let s = String(bytes: try take(n), encoding: .utf8) else { throw CodecError.invalidUTF8 }
        return s
    }

    /// IPv4 as Soulseek sends it: 4 bytes, least-significant octet first.
    public mutating func ipaddr() throws -> String {
        let b = try take(4)
        return "\(b[3]).\(b[2]).\(b[1]).\(b[0])"
    }
}

func leU32(_ b: [UInt8]) -> UInt32 {
    UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
}