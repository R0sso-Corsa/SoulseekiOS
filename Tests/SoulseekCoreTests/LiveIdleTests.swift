import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Diagnostic: does the server keep an idle connection alive for 90s?
final class LiveIdleTests: XCTestCase {
    func testIdleConnectionSurvives() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — opt-in")
        }
        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else {
            XCTFail("login failed: \(await conn.state)")
            return
        }
        print("IDLE: connected, waiting 90s")
        try await Task.sleep(nanoseconds: 90_000_000_000)
        let state = await conn.state
        print("IDLE: state after 90s = \(state)")
        if case .connected = state {} else {
            XCTFail("connection lost while idle: \(state)")
        }
        await conn.disconnect()
    }

    /// Same, but with the search listener up (port re-advertised) — the app's
    /// exact posture. Does the server keep us connected for 90s?
    func testIdleWithListenerSurvives() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — opt-in")
        }
        let conn = ServerConnection()
        let search = SearchEngine(server: conn)
        let transfers = TransferEngine(server: conn, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else {
            XCTFail("login failed: \(await conn.state)")
            return
        }
        await search.startListening()
        print("IDLE-L: listening, waiting 90s")
        try await Task.sleep(nanoseconds: 90_000_000_000)
        let state = await conn.state
        print("IDLE-L: state after 90s = \(state)")
        if case .connected = state {} else {
            XCTFail("connection lost while idle with listener: \(state)")
        }
        await transfers.shutdown()
        await search.shutdown()
        await conn.disconnect()
    }
}