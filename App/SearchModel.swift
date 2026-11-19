import Foundation
import SoulseekCore
import SoulseekProtocol

/// Bridges SearchEngine state into SwiftUI observation; applies filters and
/// groups files by (user, folder). Recompute is throttled while results stream.
@MainActor
@Observable
final class SearchModel {
    struct ResultGroup: Identifiable, Equatable, Sendable {
        let id: String
        let username: String
        let folder: String
        let freeSlots: Bool
        let avgSpeed: UInt32
        let files: [FileEntry]
    }

    var queryText = ""
    var minBitrate = 0 { didSet { scheduleRecompute() } }
    var minBitDepth = 0 { didSet { scheduleRecompute() } }
    var freeSlotsOnly = false { didSet { scheduleRecompute() } }
    var losslessOnly = false { didSet { scheduleRecompute() } }

    private(set) var engineState = SearchEngine.State()
    private(set) var groups: [ResultGroup] = []

    private let engine: SearchEngine
    private let transferEngine: TransferEngine?
    private var stateTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?

    init(engine: SearchEngine, transferEngine: TransferEngine? = nil) {
        self.engine = engine
        self.transferEngine = transferEngine
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

    func download(_ file: FileEntry, from username: String) {
        Task { await transferEngine?.download(username: username, filename: file.path, size: file.size) }
    }

    /// Browse results carry basenames; the full path is folder + separator + name.
    func download(path: String, size: UInt64, from username: String) {
        Task { await transferEngine?.download(username: username, filename: path, size: size) }
    }

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        let replies = engineState.replies
        let freeSlotsOnly = self.freeSlotsOnly
        let losslessOnly = self.losslessOnly
        let minBitrate = self.minBitrate
        let minBitDepth = self.minBitDepth
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            // Heavy grouping runs OFF the main actor — 200k+ files must not
            // block UI rendering while replies stream in.
            let groups = await Task.detached(priority: .userInitiated) {
                Self.computeGroups(
                    replies: replies,
                    freeSlotsOnly: freeSlotsOnly,
                    losslessOnly: losslessOnly,
                    minBitrate: minBitrate,
                    minBitDepth: minBitDepth
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.groups = groups
        }
    }

    /// UI cap: render at most this many files; the network keeps everything.
    nonisolated static let maxRenderedFiles = 5000

    nonisolated private static func computeGroups(
        replies: [SearchReply],
        freeSlotsOnly: Bool,
        losslessOnly: Bool,
        minBitrate: Int,
        minBitDepth: Int
    ) -> [ResultGroup] {
        var result: [ResultGroup] = []
        var totalFiles = 0
        for reply in replies {
            if freeSlotsOnly && !reply.freeSlots { continue }
            var byFolder: [String: [FileEntry]] = [:]
            for file in reply.files where passes(file, losslessOnly: losslessOnly, minBitrate: minBitrate, minBitDepth: minBitDepth) {
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
                totalFiles += files.count
                if totalFiles >= maxRenderedFiles { return result }
            }
        }
        return result
    }

    nonisolated private static func passes(_ f: FileEntry, losslessOnly: Bool, minBitrate: Int, minBitDepth: Int) -> Bool {
        let lossless = ["flac", "wav", "alac", "ape", "wv"].contains(f.ext)
        if losslessOnly && !lossless { return false }
        if minBitrate > 0 {
            if let bitrate = f.bitrate, bitrate > 0 {
                if bitrate < UInt32(minBitrate) { return false }
            } else if !lossless {
                return false // unknown bitrate on a lossy file
            }
        }
        if minBitDepth > 0 {
            // Bit depth is only meaningful when reported; unknowns are excluded.
            guard let bitness = f.bitness, bitness >= UInt32(minBitDepth) else { return false }
        }
        return true
    }
}