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
        public var lastActivity = Date()
    }

    public private(set) var conversations: [Conversation] = []
    public private(set) var roomList: RoomList?
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
        try? await server.send(frame: ServerMessages.joinRoom(room: name, type: isPrivate ? 1 : 0))
    }

    public func leaveRoom(_ name: String) async {
        try? await server.send(frame: ServerMessages.leaveRoom(room: name))
    }

    public func say(in room: String, text: String) async {
        guard !text.isEmpty else { return }
        try? await server.send(frame: ServerMessages.sayInRoom(room: room, message: text))
        // The server echoes our own room message back via code 13.
    }

    public func requestRoomList() async {
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