import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in live search acceptance against the real Soulseek network.
/// Skipped unless SLSK_USER / SLSK_PASS are set. Throwaway account only.
/// This exercises the indirect path for real: we are behind NAT, responders
/// must use ConnectToPeer and we dial out.
final class LiveSearchTests: XCTestCase {
    func testLiveSearchReturnsResults() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live search test is opt-in")
        }

        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else {
            XCTFail("login failed: \(await conn.state)")
            return
        }

        let engine = SearchEngine(server: conn)
        await engine.startListening()
        try await Task.sleep(nanoseconds: 500_000_000) // let the port advertisement land

        await engine.search("flac", timeout: 25)
        let deadline = Date().addingTimeInterval(30)
        var state = await engine.state
        while Date() < deadline && !state.finished {
            try await Task.sleep(nanoseconds: 500_000_000)
            state = await engine.state
        }

        let fileCount = state.replies.reduce(0) { $0 + $1.files.count }
        print("LIVE SEARCH: query=flac replies=\(state.replies.count) files=\(fileCount) listenPort=\(state.listenPort) finished=\(state.finished)")
        for reply in state.replies.prefix(3) {
            print("  \(reply.username): \(reply.files.count) files, slots=\(reply.freeSlots), speed=\(reply.avgSpeed)")
            if let f = reply.files.first {
                print("    e.g. \(f.filename) [\(f.ext) bitrate=\(f.bitrate ?? 0) size=\(f.size)]")
            }
        }
        XCTAssertFalse(state.replies.isEmpty, "no live search results — indirect path may be broken")

        await engine.shutdown()
        await conn.disconnect()
    }
}