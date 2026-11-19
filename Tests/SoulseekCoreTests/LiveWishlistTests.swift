import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in live wishlist gate: a saved search re-run via WishlistSearch(103)
/// returns real results and persists to disk.
final class LiveWishlistTests: XCTestCase {
    func testLiveWishlistRun() async throws {
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
        let search = SearchEngine(server: conn)
        await search.startListening()
        try await Task.sleep(nanoseconds: 500_000_000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let wish = WishlistEngine(server: conn, searchEngine: search, storeURL: url, interval: 9999, searchTimeout: 15)

        await wish.add("mp3")
        let items = await wish.items
        await wish.runNow(items[0].id)
        let after = await wish.items
        print("LIVE WISHLIST: query=mp3 results=\(after[0].lastResultCount)")
        XCTAssertGreaterThan(after[0].lastResultCount, 0, "wishlist search returned nothing")
        XCTAssertNotNil(after[0].lastRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "wishlist not persisted")

        await wish.shutdown()
        await search.shutdown()
        await conn.disconnect()
    }
}