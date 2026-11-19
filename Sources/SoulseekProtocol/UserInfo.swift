import Foundation

/// GetUserStats (server code 36) reply. Layout doc-verified 2026-11-19:
/// username, avg speed u32, upload count u32, unknown u32, files u32, folders u32.
public struct UserStats: Equatable, Sendable {
    public let username: String
    public let avgSpeed: UInt32
    public let uploadCount: UInt32
    public let files: UInt32
    public let folders: UInt32

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        username = try r.string()
        avgSpeed = try r.u32()
        uploadCount = try r.u32()
        _ = try r.u32() // unknown
        files = try r.u32()
        folders = try r.u32()
    }
}

/// GetUserStatus (server code 7) reply: username, status u32, privileged u8.
public struct UserStatus: Equatable, Sendable {
    public enum Status: UInt32, Sendable {
        case offline = 0, away = 1, online = 2
    }

    public let username: String
    public let status: Status
    public let privileged: Bool

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        username = try r.string()
        status = Status(rawValue: try r.u32()) ?? .offline
        privileged = try r.u8() != 0
    }
}