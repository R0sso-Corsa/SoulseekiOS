import Foundation

/// RoomTickers(113): the room wall — per-user ticker messages.
public struct RoomTickers: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let username: String
        public let message: String
    }

    public let room: String
    public let entries: [Entry]

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        room = try r.string()
        let count = try r.u32()
        guard count <= 10_000 else { throw CodecError.truncated }
        var entries: [Entry] = []
        for _ in 0..<count {
            entries.append(Entry(username: try r.string(), message: try r.string()))
        }
        self.entries = entries
    }
}

extension ServerMessages {
    /// Code 116. Set our ticker in a room; empty message removes it.
    public static func setRoomTicker(room: String, message: String) -> Data {
        var w = MessageWriter()
        w.string(room)
        w.string(message)
        return w.frame(code: 116)
    }
}