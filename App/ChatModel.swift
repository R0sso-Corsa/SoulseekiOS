import Foundation
import SoulseekCore
import SoulseekProtocol

/// Bridges ChatEngine into SwiftUI observation.
@MainActor
@Observable
final class ChatModel {
    private(set) var conversations: [ChatEngine.Conversation] = []
    private(set) var roomList: RoomList?
    private(set) var roomError: String?
    private(set) var invitationsEnabled = true

    private let engine: ChatEngine
    private var task: Task<Void, Never>?

    init(engine: ChatEngine) {
        self.engine = engine
        task = Task { [weak self] in
            guard let stream = self?.engine.updates else { return }
            for await convs in stream {
                self?.conversations = convs.sorted { $0.lastActivity > $1.lastActivity }
                self?.roomError = await engine.roomError
                self?.invitationsEnabled = await engine.invitationsEnabled
            }
        }
    }

    func conversation(_ id: String) -> ChatEngine.Conversation? {
        conversations.first { $0.id == id }
    }

    func sendPM(to username: String, text: String) {
        Task { await engine.sendPrivateMessage(to: username, text: text) }
    }

    func joinRoom(_ name: String, private isPrivate: Bool = false) {
        Task { await engine.joinRoom(name, private: isPrivate) }
    }

    func leaveRoom(_ name: String) {
        Task { await engine.leaveRoom(name) }
    }

    func say(in room: String, text: String) {
        Task { await engine.say(in: room, text: text) }
    }

    func setTicker(in room: String, message: String) {
        Task { await engine.setTicker(in: room, message: message) }
    }

    // MARK: - Private rooms

    func invite(_ username: String, to room: String) {
        Task { await engine.invite(username, to: room) }
    }

    func removeMember(_ username: String, from room: String) {
        Task { await engine.removeMember(username, from: room) }
    }

    func makeOperator(_ username: String, in room: String) {
        Task { await engine.makeOperator(username, in: room) }
    }

    func removeOperator(_ username: String, in room: String) {
        Task { await engine.removeOperator(username, in: room) }
    }

    func leavePrivateRoom(_ name: String) {
        Task { await engine.leavePrivateRoom(name) }
    }

    func cancelOwnership(of name: String) {
        Task { await engine.cancelOwnership(of: name) }
    }

    func setInvitationsEnabled(_ enable: Bool) {
        Task { await engine.setInvitationsEnabled(enable) }
    }

    func clearRoomError() {
        roomError = nil
    }

    func share(_ card: MusicCard, to conversationID: String) {
        Task { await engine.shareMusic(card, to: conversationID) }
    }

    func sendMedia(_ card: MediaCard, to conversationID: String) {
        Task { await engine.sendMedia(card, to: conversationID) }
    }

    func refreshRoomList() {
        Task {
            await engine.requestRoomList()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if let list = await engine.roomList {
                    self.roomList = list
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
}