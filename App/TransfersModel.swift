import Foundation
import SoulseekCore

/// Bridges TransferEngine updates into SwiftUI observation; tracks speed.
@MainActor
@Observable
final class TransfersModel {
    private(set) var transfers: [TransferEngine.Transfer] = []
    private(set) var speeds: [UUID: Double] = [:]
    private var lastSnapshot: [UUID: (received: UInt64, time: Date)] = [:]

    private let engine: TransferEngine
    private var task: Task<Void, Never>?

    init(engine: TransferEngine) {
        self.engine = engine
        task = Task { [weak self] in
            guard let stream = self?.engine.updates else { return }
            for await list in stream {
                self?.apply(list)
            }
        }
    }

    func retry(_ id: UUID) { Task { await engine.retry(id) } }
    func cancel(_ id: UUID) { Task { await engine.cancel(id) } }
    func clearCompleted() { Task { await engine.clearCompleted() } }
    func queuePlace(_ id: UUID) { Task { await engine.requestQueuePlace(id) } }

    private func apply(_ list: [TransferEngine.Transfer]) {
        let now = Date()
        for t in list {
            if let last = lastSnapshot[t.id] {
                let dt = now.timeIntervalSince(last.time)
                if dt > 0.2 {
                    let delta = Double(t.received) - Double(last.received)
                    speeds[t.id] = max(0, delta / dt)
                    lastSnapshot[t.id] = (t.received, now)
                }
            } else {
                lastSnapshot[t.id] = (t.received, now)
            }
        }
        transfers = list
    }
}