import Foundation
import SoulseekProtocol

/// Chat: private messages (auto-acked) + rooms (group chats). Rooms are
/// created on demand by JoinRoom — that's the "make a group chat" feature.
/// Music sharing = MusicCard text lines (AD-12), rendered as download cards.
public actor ChatEngine {
    public struct ChatMessage: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let serverID: UInt32?
        public let sender: String
        public let text: String
        public let date: Date
        public let isMine: Bool
        public let isSystem: Bool
        public let card: MusicCard?

        init(serverID: UInt32? = nil, sender: String, text: String, date: Date = Date(),
             isMine: Bool, isSystem: Bool = false) {
            self.id = UUID()
            self.serverID = serverID
            self.sender = sender
            self.text = text
            self.date = date
            self.isMine = isMine
            self.isSystem = isSystem
            self.card = isSystem ? nil : MusicCard.parse(text)
        }
    }

    public enum ConversationKind: String, Sendable {
        case pm, room
    }

    public struct Conversation: Identifiable, Equatable, Sendable {
        public let id: String          // "pm:<user>" or "room:<name>"
        public let kind: ConversationKind
        public let name: String
        public var messages: [ChatMessage] = []
        public var members: [RoomMember] = []
        public var owner: String?
        public var tickers: [String: String] = [:]
        public var isPrivate = false
        public var privateMembers: [String] = []
        public var operators: [String] = []
        public var lastActivity = Date()
    }

    public private(set) var conversations: [Conversation] = []
    public private(set) var roomList: RoomList?
    /// Last room-creation error (CantCreateRoom 1003), for the create alert.
    public private(set) var roomError: String?
    /// Whether we accept private-room invitations (EnableRoomInvitations 141).
    public private(set) var invitationsEnabled = true
    public nonisolated let updates: AsyncStream<[Conversation]>
    private let updatesContinuation: AsyncStream<[Conversation]>.Continuation

    private let server: ServerConnection
    private var eventTask: Task<Void, Never>?

    public init(server: ServerConnection) {
        self.server = server
        var cont: AsyncStream<[Conversation]>.Continuation?
        updates = AsyncStream { cont = $0 }
        updatesContinuation = cont!
        eventTask = Task { await self.consumeEvents() }
    }

    deinit {
        updatesContinuation.finish()
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: - Sending

    public func sendPrivateMessage(to username: String, text: String) async {
        guard !text.isEmpty, !username.isEmpty else { return }
        try? await server.send(frame: ServerMessages.messageUser(username: username, message: text))
        let me = await server.username
        append(to: "pm:\(username)", kind: .pm, name: username,
               message: ChatMessage(sender: me, text: text, isMine: true))
    }

    /// Join a room — creates it if it doesn't exist (server behavior).
    /// type: public by default; private rooms are invite-only groups.
    public func joinRoom(_ name: String, private isPrivate: Bool = false) async {
        guard Self.isValidRoomName(name) else { return }
        roomError = nil
        try? await server.send(frame: ServerMessages.joinRoom(room: name, type: isPrivate ? 1 : 0))
    }

    // MARK: - Private rooms

    /// Invite a user (AddRoomMember 134; owner/operator only).
    /// The server does not echo 134 to the sender, so apply locally too.
    public func invite(_ username: String, to room: String) async {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? await server.send(frame: ServerMessages.addRoomMember(room: room, username: name))
        if var conv = conversation("room:\(room)"), !conv.privateMembers.contains(name) {
            conv.privateMembers.append(name)
            upsert(conv)
            system("room:\(room)", kind: .room, name: room, "\(name) was invited")
        }
    }

    /// Remove a member (RemoveRoomMember 135).
    public func removeMember(_ username: String, from room: String) async {
        try? await server.send(frame: ServerMessages.removeRoomMember(room: room, username: username))
        if var conv = conversation("room:\(room)") {
            conv.privateMembers.removeAll { $0 == username }
            conv.operators.removeAll { $0 == username }
            upsert(conv)
            publish()
        }
    }

    /// Grant operator abilities (AddRoomOperator 143; owner only).
    public func makeOperator(_ username: String, in room: String) async {
        try? await server.send(frame: ServerMessages.addRoomOperator(room: room, username: username))
        if var conv = conversation("room:\(room)"), !conv.operators.contains(username) {
            conv.operators.append(username)
            upsert(conv)
            publish()
        }
    }

    /// Revoke operator abilities (RemoveRoomOperator 144; owner only).
    public func removeOperator(_ username: String, in room: String) async {
        try? await server.send(frame: ServerMessages.removeRoomOperator(room: room, username: username))
        if var conv = conversation("room:\(room)") {
            conv.operators.removeAll { $0 == username }
            upsert(conv)
            publish()
        }
    }

    /// Leave a private room for good (CancelRoomMembership 136).
    public func leavePrivateRoom(_ name: String) async {
        try? await server.send(frame: ServerMessages.cancelRoomMembership(room: name))
        conversations.removeAll { $0.id == "room:\(name)" }
        publish()
    }

    /// Stop owning a private room (CancelRoomOwnership 137).
    public func cancelOwnership(of name: String) async {
        try? await server.send(frame: ServerMessages.cancelRoomOwnership(room: name))
    }

    /// Accept or refuse private-room invitations (EnableRoomInvitations 141).
    public func setInvitationsEnabled(_ enable: Bool) async {
        try? await server.send(frame: ServerMessages.enableRoomInvitations(enable))
    }

    public func leaveRoom(_ name: String) async {
        try? await server.send(frame: ServerMessages.leaveRoom(room: name))
    }

    public func say(in room: String, text: String) async {
        guard !text.isEmpty else { return }
        try? await server.send(frame: ServerMessages.sayInRoom(room: room, message: text))
        // The server echoes our own room message back via code 13.
    }

    /// Set our room-wall ticker (116); empty message removes it. Applied
    /// locally too — the server echoes changes to OTHERS via 114/115 but
    /// may not echo our own back to us.
    public func setTicker(in room: String, message: String) async {
        try? await server.send(frame: ServerMessages.setRoomTicker(room: room, message: message))
        if var conv = conversation("room:\(room)") {
            let me = await server.username
            if message.isEmpty {
                conv.tickers[me] = nil
            } else {
                conv.tickers[me] = message
            }
            upsert(conv)
            publish()
        }
    }

    public func requestRoomList() async {
        // Clear the cache so waiters block until the FRESH response arrives.
        roomList = nil
        try? await server.send(frame: ServerMessages.roomList())
    }

    /// Send a music share card into a conversation ("pm:user" / "room:name").
    public func shareMusic(_ card: MusicCard, to conversationID: String) async {
        if conversationID.hasPrefix("pm:") {
            await sendPrivateMessage(to: String(conversationID.dropFirst(3)), text: card.encoded())
        } else if conversationID.hasPrefix("room:") {
            await say(in: String(conversationID.dropFirst(5)), text: card.encoded())
        }
    }

    /// Server room-name rules: non-empty ASCII ≤24 chars, no leading/trailing
    /// or consecutive spaces.
    public static func isValidRoomName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 24 && name.allSatisfy { $0.isASCII }
            && !name.hasPrefix(" ") && !name.hasSuffix(" ") && !name.contains("  ")
    }

    // MARK: - Events

    private func consumeEvents() async {
        let stream = await server.makeEventStream()
        for await event in stream {
            if Task.isCancelled { return }
            switch event {
            case .privateMessage(let pm):
                let convID = "pm:\(pm.username)"
                let duplicate = conversation(convID)?.messages.contains { $0.serverID == pm.id } ?? false
                if !duplicate {
                    append(to: convID, kind: .pm, name: pm.username,
                           message: ChatMessage(serverID: pm.id, sender: pm.username, text: pm.message,
                                                date: Date(timeIntervalSince1970: TimeInterval(pm.timestamp)),
                                                isMine: false))
                }
                // Ack even duplicates — the server resends until acked.
                try? await server.send(frame: ServerMessages.messageAcked(id: pm.id))
            case .roomMessage(let rm):
                let me = await server.username
                append(to: "room:\(rm.room)", kind: .room, name: rm.room,
                       message: ChatMessage(sender: rm.username, text: rm.message, isMine: rm.username == me))
            case .roomJoined(let rj):
                var conv = conversation("room:\(rj.room)") ?? Conversation(id: "room:\(rj.room)", kind: .room, name: rj.room)
                conv.members = rj.members
                conv.owner = rj.owner
                conv.isPrivate = rj.owner != nil
                conv.operators = rj.operators
                conv.privateMembers = rj.members.map(\.username)
                upsert(conv)
                system("room:\(rj.room)", kind: .room, name: rj.room, "Joined \(rj.room)")
            case .roomLeft(let room):
                conversations.removeAll { $0.id == "room:\(room)" }
                publish()
            case .userJoinedRoom(let uj):
                if var conv = conversation("room:\(uj.room)") {
                    if !conv.members.contains(where: { $0.username == uj.member.username }) {
                        conv.members.append(uj.member)
                    }
                    upsert(conv)
                    system("room:\(uj.room)", kind: .room, name: uj.room, "\(uj.member.username) joined")
                }
            case .userLeftRoom(let ul):
                if var conv = conversation("room:\(ul.room)") {
                    conv.members.removeAll { $0.username == ul.username }
                    upsert(conv)
                    system("room:\(ul.room)", kind: .room, name: ul.room, "\(ul.username) left")
                }
            case .roomList(let list):
                roomList = list
            case .roomTickers(let tickers):
                if var conv = conversation("room:\(tickers.room)") {
                    conv.tickers = Dictionary(uniqueKeysWithValues: tickers.entries.map { ($0.username, $0.message) })
                    upsert(conv)
                    publish()
                }
            case .roomTickerAdded(let room, let username, let message):
                if var conv = conversation("room:\(room)") {
                    conv.tickers[username] = message
                    upsert(conv)
                    publish()
                }
            case .roomTickerRemoved(let room, let username):
                if var conv = conversation("room:\(room)") {
                    conv.tickers[username] = nil
                    upsert(conv)
                    publish()
                }
            case .roomMembers(let room, let members):
                if var conv = conversation("room:\(room)") {
                    conv.privateMembers = members
                    upsert(conv)
                    publish()
                }
            case .roomMemberAdded(let room, let username):
                if var conv = conversation("room:\(room)") {
                    if !conv.privateMembers.contains(username) {
                        conv.privateMembers.append(username)
                    }
                    upsert(conv)
                    system("room:\(room)", kind: .room, name: room, "\(username) was invited")
                }
            case .roomMemberRemoved(let room, let username):
                if var conv = conversation("room:\(room)") {
                    conv.privateMembers.removeAll { $0 == username }
                    conv.operators.removeAll { $0 == username }
                    upsert(conv)
                    system("room:\(room)", kind: .room, name: room, "\(username) was removed")
                }
            case .roomMembershipGranted(let room):
                // Invited to a private room — join it automatically.
                system("room:\(room)", kind: .room, name: room, "You were invited to \(room)")
                await joinRoom(room, private: true)
            case .roomMembershipRevoked(let room):
                conversations.removeAll { $0.id == "room:\(room)" }
                publish()
            case .roomInvitationsEnabled(let enable):
                invitationsEnabled = enable
                publish()
            case .roomOperatorAdded(let room, let username):
                if var conv = conversation("room:\(room)") {
                    if !conv.operators.contains(username) { conv.operators.append(username) }
                    upsert(conv)
                    system("room:\(room)", kind: .room, name: room, "\(username) is now an operator")
                }
            case .roomOperatorRemoved(let room, let username):
                if var conv = conversation("room:\(room)") {
                    conv.operators.removeAll { $0 == username }
                    upsert(conv)
                    system("room:\(room)", kind: .room, name: room, "\(username) is no longer an operator")
                }
            case .roomOperatorshipGranted(let room):
                if var conv = conversation("room:\(room)") {
                    let me = await server.username
                    if !conv.operators.contains(me) { conv.operators.append(me) }
                    upsert(conv)
                    system("room:\(room)", kind: .room, name: room, "You are now an operator")
                }
            case .roomOperatorshipRevoked(let room):
                if var conv = conversation("room:\(room)") {
                    let me = await server.username
                    conv.operators.removeAll { $0 == me }
                    upsert(conv)
                    system("room:\(room)", kind: .room, name: room, "Your operator abilities were removed")
                }
            case .roomOperators(let room, let operators):
                if var conv = conversation("room:\(room)") {
                    conv.operators = operators
                    upsert(conv)
                    publish()
                }
            case .cantCreateRoom(let room):
                roomError = "Couldn't create \"\(room)\" — the name is used by a private group."
                publish()
            default:
                break
            }
        }
    }

    // MARK: - State helpers

    private func conversation(_ id: String) -> Conversation? {
        conversations.first { $0.id == id }
    }

    private func upsert(_ conv: Conversation) {
        if let i = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[i] = conv
        } else {
            conversations.append(conv)
        }
    }

    private func append(to id: String, kind: ConversationKind, name: String, message: ChatMessage) {
        var conv = conversation(id) ?? Conversation(id: id, kind: kind, name: name)
        conv.messages.append(message)
        conv.lastActivity = Date()
        upsert(conv)
        publish()
    }

    private func system(_ id: String, kind: ConversationKind, name: String, _ text: String) {
        append(to: id, kind: kind, name: name,
               message: ChatMessage(sender: "", text: text, isMine: false, isSystem: true))
    }

    private func publish() {
        updatesContinuation.yield(conversations)
    }
}