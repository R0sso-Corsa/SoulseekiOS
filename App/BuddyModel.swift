import Foundation
import SoulseekCore

/// MainActor bridge for the buddy list.
@MainActor
@Observable
final class BuddyModel {
    private(set) var buddies: [BuddyEngine.Buddy] = []
    var error: String?
    private let engine: BuddyEngine
    private var task: Task<Void, Never>?

    init(engine: BuddyEngine) {
        self.engine = engine
        task = Task { [weak self] in
            guard let stream = self?.engine.updates else { return }
            for await list in stream {
                self?.buddies = list
            }
        }
        Task { self.buddies = await engine.buddies }
    }

    func add(_ username: String) {
        error = nil
        Task {
            do { try await engine.add(username) }
            catch { self.error = "Couldn't add \(username): \(error.localizedDescription)" }
        }
    }

    func remove(_ username: String) {
        Task { await engine.remove(username) }
    }
}