import Foundation
import SoulseekCore

/// Bridges UploadEngine into SwiftUI observation.
@MainActor
@Observable
final class UploadsModel {
    private(set) var uploads: [UploadEngine.Upload] = []
    private(set) var slots: Int = 2

    private let engine: UploadEngine
    private var task: Task<Void, Never>?

    init(engine: UploadEngine) {
        self.engine = engine
        task = Task { [weak self] in
            guard let stream = self?.engine.updates else { return }
            for await list in stream {
                self?.uploads = list
            }
        }
        Task { self.slots = await engine.slots }
    }

    func cancel(_ id: UUID) { Task { await engine.cancel(id) } }
    func clearCompleted() { Task { await engine.clearCompleted() } }
    func setSlots(_ n: Int) {
        slots = max(1, n)
        Task { await engine.setSlots(max(1, n)) }
    }
}