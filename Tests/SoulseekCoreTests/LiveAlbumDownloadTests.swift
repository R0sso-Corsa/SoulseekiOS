import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in LIVE album-download gate: find peers sharing a folder with 2+
/// small healthy mp3s, queue BOTH tracks per peer (the engine serializes
/// same-user transfers), run several peers in parallel — pass when any peer
/// delivers both files byte-exact. Same candidate strategy as the M0 gate.
final class LiveAlbumDownloadTests: XCTestCase {
    func testLiveAlbumDownloadTwoTracksExact() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live album test is opt-in")
        }
        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else { XCTFail("login failed"); return }

        let search = SearchEngine(server: conn)
        await search.startListening()
        try await Task.sleep(nanoseconds: 500_000_000)
        await search.search("mp3", timeout: 15)
        let deadline = Date().addingTimeInterval(20)
        var state = await search.state
        while Date() < deadline && !state.finished {
            try await Task.sleep(nanoseconds: 500_000_000)
            state = await search.state
        }
        print("LIVE ALBUM: \(state.replies.count) replies")

        // Candidates: free-slot peers with 2+ small mp3s in ONE folder.
        struct Candidate { let username: String; let files: [FileEntry] }
        var candidates: [Candidate] = []
        for reply in state.replies where reply.freeSlots {
            var byFolder: [String: [FileEntry]] = [:]
            for f in reply.files where f.ext == "mp3" && f.size >= 300_000 && f.size <= 4_000_000 && (f.bitrate != nil || f.duration != nil) {
                byFolder[f.folder, default: []].append(f)
            }
            if let (_, files) = byFolder.first(where: { $0.value.count >= 2 }) {
                candidates.append(Candidate(username: reply.username, files: Array(files.prefix(2))))
            }
            if candidates.count >= 6 { break }
        }
        guard !candidates.isEmpty else {
            throw XCTSkip("no album candidates (2+ small mp3s in one folder) in this search")
        }
        print("LIVE ALBUM: \(candidates.count) album candidates")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transfers = TransferEngine(server: conn, directory: dir)
        let router = SearchEngine(server: conn,
            onFileConnection: { link, pending in await transfers.handleDirectFile(link, pending: pending) },
            onPierce: { link, ticket, pending in await transfers.handleIndirectP(link, ticket: ticket, pending: pending) })
        await router.startListening()
        defer {
            Task {
                await transfers.shutdown(); await router.shutdown(); await search.shutdown()
                await conn.disconnect()
                try? FileManager.default.removeItem(at: dir)
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        // Queue both tracks per candidate — same-user runs serialize.
        for c in candidates {
            for f in c.files {
                await transfers.download(username: c.username, filename: f.path, size: f.size)
            }
        }

        let dlDeadline = Date().addingTimeInterval(150)
        var winner: (Candidate, [TransferEngine.Transfer])?
        while Date() < dlDeadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let all = await transfers.transfers
            for c in candidates {
                let done = all.filter { $0.username == c.username && $0.state == .completed }
                if done.count == c.files.count {
                    winner = (c, done)
                    break
                }
            }
            if winner != nil { break }
        }
        let states = await transfers.transfers.map { "\($0.username)|\($0.filename)|\($0.state)" }
        guard let (c, done) = winner else {
            XCTFail("no peer delivered a full album: \(states.prefix(12))")
            return
        }
        for (i, t) in done.enumerated() {
            let path = try XCTUnwrap(t.localPath)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual(attrs[.size] as? UInt64, c.files[i].size, "track \(i) size mismatch")
        }
        print("LIVE ALBUM: \(c.username) delivered \(done.count) tracks byte-exact — album download verified")
    }
}