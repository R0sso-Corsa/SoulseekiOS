import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Regression probe: peer address resolution AFTER a search has run to
/// completion (the app's exact sequence when tapping download).
final class LiveAddressTests: XCTestCase {
    func testLivePeerAddressAfterSearch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live address test is opt-in")
        }
        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else {
            XCTFail("login failed: \(await conn.state)")
            return
        }
        let search = SearchEngine(server: conn)
        await search.startListening()
        try await Task.sleep(nanoseconds: 500_000_000)
        await search.search("flac", timeout: 15)
        let deadline = Date().addingTimeInterval(20)
        var state = await search.state
        while Date() < deadline && !state.finished {
            try await Task.sleep(nanoseconds: 500_000_000)
            state = await search.state
        }
        XCTAssertFalse(state.replies.isEmpty, "no search replies")
        for reply in state.replies.prefix(3) {
            let addr = try await conn.peerAddress(for: reply.username)
            print("LIVE ADDR: \(reply.username) -> \(addr.ip):\(addr.port) online=\(addr.isOnline)")
        }
        await search.shutdown()
        await conn.disconnect()
    }
}