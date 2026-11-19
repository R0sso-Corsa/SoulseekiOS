import Foundation
import SoulseekCore

/// Bridges WishlistEngine into SwiftUI observation.
@MainActor
@Observable
final class WishlistModel {
    private(set) var items: [WishlistEngine.Item] = []

    private let engine: WishlistEngine
    private var task: Task<Void, Never>?

    init(engine: WishlistEngine) {
        self.engine = engine
        task = Task { [weak self] in
            guard let stream = self?.engine.updates else { return }
            for await items in stream {
                self?.items = items
            }
        }
        Task { self.items = await engine.items }
    }

    func add(_ query: String) { Task { await engine.add(query) } }
    func remove(_ id: UUID) { Task { await engine.remove(id) } }
    func runNow(_ id: UUID) { Task { await engine.runNow(id) } }
    func runAll() { Task { await engine.runAll() } }
}