import Foundation

/// MessageUser (server 22) received: a private message.
public struct PrivateMessage: Equatable, Sendable {
    public let id: UInt32
    public let timestamp: UInt32
    public let username: String
    public let message: String
    public let isNew: Bool

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        id = try r.u32()
        timestamp = try r.u32()
        username = try r.string()
        message = try r.string()
        isNew = (try? r.u8()) != 0
    }
}

/// SayChatroom (server 13) received: room, username, message.
public struct RoomMessage: Equatable, Sendable {
    public let room: String
    public let username: String
    public let message: String

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        room = try r.string()
        username = try r.string()
        message = try r.string()
    }
}

/// One member of a room, from JoinRoom/UserJoinedRoom parallel arrays.
public struct RoomMember: Equatable, Sendable {
    public let username: String
    public let status: UInt32
    public let avgSpeed: UInt32
    public let uploadCount: UInt32
    public let files: UInt32
    public let folders: UInt32
    public let slotsFull: Bool
    public let country: String
}

/// JoinRoom (server 14) received. Parallel arrays: users, statuses, stats
/// (5×u32 each), slots, countries; private rooms append owner + operators.
public struct RoomJoined: Equatable, Sendable {
    public let room: String
    public let members: [RoomMember]
    public let owner: String?
    public let operators: [String]

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        room = try r.string()
        let count = try r.u32()
        guard count <= 100_000 else { throw CodecError.truncated }
        var names: [String] = []
        for _ in 0..<count { names.append(try r.string()) }
        let statusCount = try r.u32()
        var statuses: [UInt32] = []
        for _ in 0..<statusCount { statuses.append(try r.u32()) }
        let statsCount = try r.u32()
        var stats: [(UInt32, UInt32, UInt32, UInt32)] = []
        for _ in 0..<statsCount {
            let speed = try r.u32()
            let uploads = try r.u32()
            _ = try r.u32() // unknown
            let files = try r.u32()
            let folders = try r.u32()
            stats.append((speed, uploads, files, folders))
        }
        let slotsCount = try r.u32()
        var slots: [Bool] = []
        for _ in 0..<slotsCount { slots.append(try r.u32() != 0) }
        let countryCount = try r.u32()
        var countries: [String] = []
        for _ in 0..<countryCount { countries.append(try r.string()) }

        var result: [RoomMember] = []
        for (i, name) in names.enumerated() {
            let st = i < stats.count ? stats[i] : (0, 0, 0, 0)
            result.append(RoomMember(
                username: name,
                status: i < statuses.count ? statuses[i] : 0,
                avgSpeed: st.0,
                uploadCount: st.1,
                files: st.2,
                folders: st.3,
                slotsFull: i < slots.count ? slots[i] : false,
                country: i < countries.count ? countries[i] : ""
            ))
        }
        members = result

        if r.remaining > 0 {
            owner = try r.string()
            let opCount = try r.u32()
            var ops: [String] = []
            for _ in 0..<opCount { ops.append(try r.string()) }
            operators = ops
        } else {
            owner = nil
            operators = []
        }
    }
}

/// UserJoinedRoom (server 16) received.
public struct UserJoinedRoom: Equatable, Sendable {
    public let room: String
    public let member: RoomMember

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        room = try r.string()
        let name = try r.string()
        let status = try r.u32()
        let speed = try r.u32()
        let uploads = try r.u32()
        _ = try r.u32() // unknown
        let files = try r.u32()
        let folders = try r.u32()
        let slots = try r.u32() != 0
        let country = (try? r.string()) ?? ""
        member = RoomMember(username: name, status: status, avgSpeed: speed,
                            uploadCount: uploads, files: files, folders: folders,
                            slotsFull: slots, country: country)
    }
}

/// UserLeftRoom (server 17) received.
public struct UserLeftRoom: Equatable, Sendable {
    public let room: String
    public let username: String

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        room = try r.string()
        username = try r.string()
    }
}

/// One room entry in a RoomList.
public struct RoomInfo: Equatable, Sendable {
    public let name: String
    public let userCount: UInt32
}

/// RoomList (server 64) received: public rooms, owned private rooms, other
/// private rooms, operated rooms — names and counts in parallel arrays.
public struct RoomList: Equatable, Sendable {
    public let publicRooms: [RoomInfo]
    public let ownedPrivateRooms: [RoomInfo]
    public let privateRooms: [RoomInfo]
    public let operatedRooms: [String]

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        func names() throws -> [String] {
            let n = try r.u32()
            guard n <= 100_000 else { throw CodecError.truncated }
            var out: [String] = []
            for _ in 0..<n { out.append(try r.string()) }
            return out
        }
        func counts() throws -> [UInt32] {
            let n = try r.u32()
            guard n <= 100_000 else { throw CodecError.truncated }
            var out: [UInt32] = []
            for _ in 0..<n { out.append(try r.u32()) }
            return out
        }
        func zip(_ ns: [String], _ cs: [UInt32]) -> [RoomInfo] {
            ns.enumerated().map { RoomInfo(name: $1, userCount: $0 < cs.count ? cs[$0] : 0) }
        }
        let pubNames = try names()
        let pubCounts = try counts()
        publicRooms = zip(pubNames, pubCounts)
        if r.remaining >= 4 {
            let ownedNames = try names()
            let ownedCounts = try counts()
            ownedPrivateRooms = zip(ownedNames, ownedCounts)
        } else {
            ownedPrivateRooms = []
        }
        if r.remaining >= 4 {
            let privNames = try names()
            let privCounts = try counts()
            privateRooms = zip(privNames, privCounts)
        } else {
            privateRooms = []
        }
        if r.remaining >= 4 {
            operatedRooms = try names()
        } else {
            operatedRooms = []
        }
    }
}