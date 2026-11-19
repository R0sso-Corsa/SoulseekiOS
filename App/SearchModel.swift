import Foundation
import SoulseekCore
import SoulseekProtocol

/// Bridges SearchEngine state into SwiftUI observation; applies filters and
/// groups files by (user, folder). Recompute is throttled while results stream.
@MainActor
@Observable
final class SearchModel {
    struct ResultGroup: Identifiable, Equatable {
        let id: String
        let username: String
        let folder: String
        let freeSlots: Bool
        let avgSpeed: UInt32
        let files: [FileEntry]
    }

    var queryText = ""
    var minBitrate = 0 { didSet { scheduleRecompute() } }
    var freeSlotsOnly = false { didSet { scheduleRecompute() } }
    var losslessOnly = false { didSet { scheduleRecompute() } }

    private(set) var engineState = SearchEngine.State()
    private(set) var groups: [ResultGroup] = []

    private let engine: SearchEngine
    private var stateTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?

    init(engine: SearchEngine) {
        self.engine = engine
        stateTask = Task { [weak self] in
            guard let stream = self?.engine.states else { return }
            for await state in stream {
                self?.engineState = state
                self?.scheduleRecompute()
            }
        }
    }

    var isSearching: Bool { engineState.isSearching }

    var statusText: String {
        let rawFiles = engineState.replies.reduce(0) { $0 + $1.files.count }
        if engineState.isSearching {
            return "Searching… \(engineState.replies.count) users, \(rawFiles) files"
        }
        if engineState.finished {
            let shown = groups.reduce(0) { $0 + $1.files.count }
            return "Done — \(shown) files in \(groups.count) folders (\(engineState.replies.count) users responded)"
        }
        return "Search the Soulseek network"
    }

    func search() {
        let q = queryText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        Task { await engine.search(q) }
    }

    func stop() {
        Task { await engine.stop() }
    }

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    private func recompute() {
        var result: [ResultGroup] = []
        for reply in engineState.replies {
            if freeSlotsOnly && !reply.freeSlots { continue }
            var byFolder: [String: [FileEntry]] = [:]
            for file in reply.files where passes(file) {
                byFolder[file.folder, default: []].append(file)
            }
            for (folder, files) in byFolder.sorted(by: { $0.key < $1.key }) {
                result.append(ResultGroup(
                    id: reply.username + "|" + folder,
                    username: reply.username,
                    folder: folder,
                    freeSlots: reply.freeSlots,
                    avgSpeed: reply.avgSpeed,
                    files: files
                ))
            }
        }
        groups = result
    }

    private func passes(_ f: FileEntry) -> Bool {
        let lossless = ["flac", "wav", "alac", "ape", "wv"].contains(f.ext)
        if losslessOnly && !lossless { return false }
        if minBitrate > 0 {
            if let bitrate = f.bitrate, bitrate > 0 {
                if bitrate < UInt32(minBitrate) { return false }
            } else if !lossless {
                return false // unknown bitrate on a lossy file
            }
        }
        return true
    }
}