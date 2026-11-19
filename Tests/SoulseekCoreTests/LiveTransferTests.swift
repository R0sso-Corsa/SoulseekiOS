import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in live download acceptance (M0 download gate). Requires SLSK_USER /
/// SLSK_PASS. Searches the live network, picks small files from users with
/// free slots, and downloads until one completes — measuring the real
/// success rate against firewalled/unreachable peers along the way.
final class LiveTransferTests: XCTestCase {
    func testLiveDownload() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live download test is opt-in")
        }

        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else {
            XCTFail("login failed: \(await conn.state)")
            return
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = TransferEngine(server: conn, directory: dir)
        let search = SearchEngine(server: conn)
        await search.startListening()
        try await Task.sleep(nanoseconds: 500_000_000)

        await search.search("mp3", timeout: 20)
        let searchDeadline = Date().addingTimeInterval(25)
        var searchState = await search.state
        while Date() < searchDeadline && !searchState.finished {
            try await Task.sleep(nanoseconds: 500_000_000)
            searchState = await search.state
        }
        print("LIVE DOWNLOAD SEARCH: replies=\(searchState.replies.count)")

        // Candidates: small mp3s with healthy metadata, ONE per user (stale
        // shares cluster per user), users with free upload slots.
        var candidates: [(user: String, file: String, size: UInt64)] = []
        for reply in searchState.replies where reply.freeSlots {
            guard !candidates.contains(where: { $0.user == reply.username }) else { continue }
            if let file = reply.files.first(where: {
                $0.ext == "mp3" && $0.size >= 300_000 && $0.size <= 4_000_000
                    && ($0.bitrate != nil || $0.duration != nil)
            }) {
                candidates.append((reply.username, file.path, file.size))
            }
            if candidates.count >= 8 { break }
        }
        XCTAssertFalse(candidates.isEmpty, "no small-file candidates with free slots")

        // Queue them all in parallel — real client behavior, and the fastest
        // way to find a reachable, healthy peer.
        for candidate in candidates {
            await engine.download(username: candidate.user, filename: candidate.file, size: candidate.size)
        }
        let deadline = Date().addingTimeInterval(150)
        var completedTransfer: TransferEngine.Transfer?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let all = await engine.transfers
            if let done = all.first(where: { $0.state == .completed }) {
                completedTransfer = done
                break
            }
            if all.allSatisfy({ t in
                if case .failed = t.state { return true }
                return t.state == .cancelled
            }) { break }
        }
        let all = await engine.transfers
        for t in all {
            print("LIVE DOWNLOAD: \(t.username) \(t.state) received=\(t.received)/\(t.size)")
        }
        let t = try XCTUnwrap(completedTransfer, "no candidate completed — indirect F path may be broken")
        let path = try XCTUnwrap(t.localPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attrs[.size] as? UInt64, t.size, "downloaded size must match advertised size")
        print("LIVE DOWNLOAD OK: \(t.username) / \(t.filename) (\(t.size) bytes)")

        await engine.shutdown()
        await search.shutdown()
        await conn.disconnect()
        try? FileManager.default.removeItem(at: dir)
    }
}