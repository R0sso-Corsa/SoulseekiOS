import Foundation
import SoulseekProtocol

/// Buddy list: WatchUser(5) per buddy, live status via GetUserStatus(7)
/// pushes. Usernames persist as JSON; stats come from the initial watch
/// reply (the server does not push stat updates).
public actor BuddyEngine {
    public struct Buddy: Identifiable, Equatable, Sendable {
        public let username: String
        public var id: String { username }
        public var exists: Bool
        public var status: UserStatus.Status
        public var avgSpeed: UInt32?
        public var files: UInt32?
        public var folders: UInt32?
        public var country: String?
    }

    public private(set) var buddies: [Buddy] = []
    public nonisolated let updates: AsyncStream<[Buddy]>
    private let updatesContinuation: AsyncStream<[Buddy]>.Continuation
    private let server: ServerConnection
    private let storeURL: URL
    private var eventTask: Task<Void, Never>?

    public init(server: ServerConnection, storeURL: URL) {
        self.server = server
        self.storeURL = storeURL
        var cont: AsyncStream<[Buddy]>.Continuation?
        updates = AsyncStream { cont = $0 }
        updatesContinuation = cont!
        if let data = try? Data(contentsOf: storeURL),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            buddies = names.map { Buddy(username: $0, exists: false, status: .offline) }
        }
        eventTask = Task { await self.consumeEvents() }
    }

    deinit {
        updatesContinuation.finish()
    }

    /// Re-watch everyone (call after connect).
    public func refreshAll() async {
        for buddy in buddies {
            if let reply = try? await server.watchUser(buddy.username) {
                apply(reply)
            }
        }
        publish()
    }

    public func add(_ username: String) async throws {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !buddies.contains(where: { $0.username == name }) else { return }
        let reply = try await server.watchUser(name)
        buddies.append(Buddy(
            username: reply.username, exists: reply.exists, status: UserStatus.Status(rawValue: reply.status ?? 0) ?? .offline,
            avgSpeed: reply.avgSpeed, files: reply.files, folders: reply.folders, country: reply.country
        ))
        persist()
        publish()
    }

    public func remove(_ username: String) async {
        buddies.removeAll { $0.username == username }
        try? await server.send(frame: ServerMessages.unwatchUser(username))
        persist()
        publish()
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
    }

    private func apply(_ reply: WatchUserReply) {
        guard let idx = buddies.firstIndex(where: { $0.username == reply.username }) else { return }
        buddies[idx].exists = reply.exists
        buddies[idx].status = UserStatus.Status(rawValue: reply.status ?? 0) ?? .offline
        buddies[idx].avgSpeed = reply.avgSpeed
        buddies[idx].files = reply.files
        buddies[idx].folders = reply.folders
        buddies[idx].country = reply.country
    }

    private func consumeEvents() async {
        let stream = await server.makeEventStream()
        for await event in stream {
            if Task.isCancelled { return }
            if case .userStatus(let status) = event,
               let idx = buddies.firstIndex(where: { $0.username == status.username }) {
                buddies[idx].status = status.status
                publish()
            }
        }
    }

    private func persist() {
        let names = buddies.map(\.username)
        try? JSONEncoder().encode(names).write(to: storeURL)
    }

    private func publish() {
        updatesContinuation.yield(buddies)
    }
}