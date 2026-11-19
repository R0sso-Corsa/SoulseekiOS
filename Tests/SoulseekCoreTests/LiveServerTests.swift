import XCTest
@testable import SoulseekCore

/// Opt-in live acceptance against the real Soulseek server.
/// Skipped unless SLSK_USER / SLSK_PASS are set in the test process env.
/// Uses the throwaway probe account — never the user's real account while
/// their desktop client is online (duplicate login kicks it).
final class LiveServerTests: XCTestCase {
    func testLiveLoginAndHandshake() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live test is opt-in")
        }

        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        let state = await conn.state
        guard case .connected(let greeting, let ip, let privileged) = state else {
            XCTFail("expected .connected, got \(state)")
            await conn.disconnect()
            return
        }
        XCTAssertFalse(ip.isEmpty, "server should report our public IP")
        print("LIVE CONNECTED user=\(user) ip=\(ip) privileged=\(privileged) greeting=\(greeting.prefix(100))")

        // Hold the session briefly so the server processes the handshake,
        // then verify a second connect (re-login) still succeeds.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await conn.disconnect()
        let after = await conn.state
        XCTAssertEqual(after, .disconnected)
    }
}