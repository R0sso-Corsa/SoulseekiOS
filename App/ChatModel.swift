import Foundation
import SoulseekCore
import SoulseekProtocol

/// Bridges ChatEngine into SwiftUI observation.
@MainActor
@Observable
final class ChatModel {
    private(set) var conversations: [ChatEngine.Conversation] = []
    private(set) var roomList: RoomList?

    private let engine: ChatEngine
    private var task: Task<Void, Never>?

    init(engine: ChatEngine) {
        self.engine = engine
        task = Task { [weak self] in
            guard let stream = self?.engine.updates else { return }
            for await convs in stream {
                self?.conversations = convs.sorted { $0.lastActivity > $1.lastActivity }
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

    func share(_ card: MusicCard, to conversationID: String) {
        Task { await engine.shareMusic(card, to: conversationID) }
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