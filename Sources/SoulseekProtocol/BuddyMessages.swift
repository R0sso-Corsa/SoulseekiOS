import Foundation

/// WatchUser(5) reply: username, exists, and when present status + stats +
/// country. Status pushes afterwards arrive as GetUserStatus(7).
public struct WatchUserReply: Equatable, Sendable {
    public let username: String
    public let exists: Bool
    public let status: UInt32?
    public let avgSpeed: UInt32?
    public let uploadCount: UInt32?
    public let files: UInt32?
    public let folders: UInt32?
    public let country: String?

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        username = try r.string()
        exists = try r.u8() != 0
        if exists {
            status = try r.u32()
            avgSpeed = try r.u32()
            uploadCount = try r.u32()
            _ = try r.u32() // unknown
            files = try r.u32()
            folders = try r.u32()
            // Country is only present for online/away users; tolerate absence.
            country = try? r.string()
        } else {
            status = nil; avgSpeed = nil; uploadCount = nil
            files = nil; folders = nil; country = nil
        }
    }
}

extension ServerMessages {
    /// Code 5. Watch a user's status (buddy list).
    public static func watchUser(_ username: String) -> Data {
        var w = MessageWriter()
        w.string(username)
        return w.frame(code: 5)
    }

    /// Code 6. Stop watching.
    public static func unwatchUser(_ username: String) -> Data {
        var w = MessageWriter()
        w.string(username)
        return w.frame(code: 6)
    }
}