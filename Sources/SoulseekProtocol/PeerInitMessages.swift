import Foundation

/// Peer initialization messages use a u8 code (not u32):
/// `[u32 length][u8 code][payload]`, length counts code + payload.
public enum PeerInitMessages {
    /// Code 1. Sent on a DIRECT peer connection we initiated.
    public static func peerInit(username: String, type: String, ticket: UInt32 = 0) -> Data {
        var w = MessageWriter()
        w.string(username)
        w.string(type)
        w.u32(ticket)
        return w.frame(initCode: 1)
    }

    /// Code 0. Sent on an INDIRECT connection in response to ConnectToPeer;
    /// the ticket is the one from that message.
    public static func pierceFirewall(ticket: UInt32) -> Data {
        var w = MessageWriter()
        w.u32(ticket)
        return w.frame(initCode: 0)
    }

    /// Parse the first frame on an inbound direct peer connection.
    /// Returns nil when more bytes are needed.
    public static func parseInitFrame(_ data: Data) throws -> (code: UInt8, payload: Data, consumed: Int)? {
        guard data.count >= 5 else { return nil }
        let bytes = [UInt8](data)
        let length = Int(leU32(Array(bytes[0..<4])))
        guard length >= 1 else { throw CodecError.truncated }
        guard data.count >= 4 + length else { return nil }
        return (bytes[4], Data(bytes[5..<(4 + length)]), 4 + length)
    }
}