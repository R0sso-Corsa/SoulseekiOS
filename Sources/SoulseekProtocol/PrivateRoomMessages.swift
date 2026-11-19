import Foundation

/// Private-room membership messages (server codes 133–148, 1003).
/// Doc-verified payload orders; see VAULT protocol facts.

/// RoomMembers(133): member list of a private room (excluding the owner).
public struct RoomMembers: Equatable, Sendable {
    public let room: String
    public let members: [String]

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        room = try r.string()
        let count = try r.u32()
        guard count <= 100_000 else { throw CodecError.truncated }
        var names: [String] = []
        for _ in 0..<count { names.append(try r.string()) }
        members = names
    }
}

/// RoomOperators(148): operator list of a private room.
public struct RoomOperators: Equatable, Sendable {
    public let room: String
    public let operators: [String]

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        room = try r.string()
        let count = try r.u32()
        guard count <= 100_000 else { throw CodecError.truncated }
        var names: [String] = []
        for _ in 0..<count { names.append(try r.string()) }
        operators = names
    }
}

extension ServerMessages {
    /// 134. Invite a user to a private room (owner/operator only).
    public static func addRoomMember(room: String, username: String) -> Data {
        var w = MessageWriter()
        w.string(room); w.string(username)
        return w.frame(code: 134)
    }

    /// 135. Remove a member (owner: anyone; operator: regular members).
    public static func removeRoomMember(room: String, username: String) -> Data {
        var w = MessageWriter()
        w.string(room); w.string(username)
        return w.frame(code: 135)
    }

    /// 136. Cancel our own membership of a private room.
    public static func cancelRoomMembership(room: String) -> Data {
        var w = MessageWriter()
        w.string(room)
        return w.frame(code: 136)
    }

    /// 137. Stop owning a private room.
    public static func cancelRoomOwnership(room: String) -> Data {
        var w = MessageWriter()
        w.string(room)
        return w.frame(code: 137)
    }

    /// 141. Enable/disable receiving private-room invitations.
    public static func enableRoomInvitations(_ enable: Bool) -> Data {
        var w = MessageWriter()
        w.u8(enable ? 1 : 0)
        return w.frame(code: 141)
    }

    /// 143. Grant operator abilities to a member.
    public static func addRoomOperator(room: String, username: String) -> Data {
        var w = MessageWriter()
        w.string(room); w.string(username)
        return w.frame(code: 143)
    }

    /// 144. Revoke operator abilities.
    public static func removeRoomOperator(room: String, username: String) -> Data {
        var w = MessageWriter()
        w.string(room); w.string(username)
        return w.frame(code: 144)
    }
}