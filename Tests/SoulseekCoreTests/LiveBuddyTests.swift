import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in live probe: WatchUser against a user who just answered a search.
final class LiveBuddyTests: XCTestCase {
    func testLiveWatchUser() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set")
        }
        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else {
            XCTFail("login failed"); return
        }
        let search = SearchEngine(server: conn)
        await search.search("mp3", timeout: 15)
        let deadline = Date().addingTimeInterval(20)
        var state = await search.state
        while Date() < deadline && state.replies.isEmpty {
            try await Task.sleep(nanoseconds: 500_000_000)
            state = await search.state
        }
        guard let target = state.replies.first?.username else {
            XCTFail("no search replies"); return
        }
        print("LIVE WATCH target: \(target)")
        do {
            let reply = try await conn.watchUser(target)
            print("LIVE WATCH OK: exists=\(reply.exists) status=\(String(describing: reply.status)) files=\(String(describing: reply.files)) country=\(String(describing: reply.country))")
        } catch {
            print("LIVE WATCH FAILED: \(error)")
        }
        await search.shutdown()
        await conn.disconnect()
    }
}