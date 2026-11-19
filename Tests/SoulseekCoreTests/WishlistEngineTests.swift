import Foundation
import Darwin
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

final class WishlistEngineTests: XCTestCase {
    private func login(_ conn: ServerConnection, _ server: FakeServer) async throws {
        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame()
        try server.send(loginSuccessFrame(greeting: "", ip: [127, 0, 0, 1], privileged: false))
        for _ in 0..<9 { _ = try server.readFrame() }
        await connecting
    }

    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    func testPersistenceRoundTrip() async throws {
        let url = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let conn = ServerConnection()
        let search = SearchEngine(server: conn)
        let w1 = WishlistEngine(server: conn, searchEngine: search, storeURL: url)
        await w1.add("ambient techno")
        await w1.add("flac")
        await w1.shutdown()

        let w2 = WishlistEngine(server: conn, searchEngine: search, storeURL: url)
        let items = await w2.items
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.query), ["ambient techno", "flac"])
        await w2.shutdown()
        await conn.disconnect()
    }

    func testIntervalSearchUsesCode103() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let search = SearchEngine(server: conn)
        try await login(conn, server)
        let url = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let wish = WishlistEngine(server: conn, searchEngine: search, storeURL: url, interval: 1, searchTimeout: 1)
        addTeardownBlock { await wish.shutdown(); await search.shutdown(); await conn.disconnect() }

        await wish.add("flac")
        // The 1s loop must fire a WishlistSearch(103), not FileSearch(26).
        let frame = try server.readFrame()
        XCTAssertEqual(frame.code, 103)
        var r = MessageReader(frame.payload)
        _ = try r.u32() // ticket
        XCTAssertEqual(try r.string(), "flac")
    }

    func testServerIntervalUpdate() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let search = SearchEngine(server: conn)
        try await login(conn, server)
        let url = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let wish = WishlistEngine(server: conn, searchEngine: search, storeURL: url, interval: 9999, searchTimeout: 1)
        addTeardownBlock { await wish.shutdown(); await search.shutdown(); await conn.disconnect() }

        var w = MessageWriter()
        w.u32(120)
        try server.send(w.frame(code: 104))
        let deadline = Date().addingTimeInterval(5)
        var got: UInt64 = 0
        while Date() < deadline {
            got = await wish.interval
            if got == 120 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(got, 120)
    }

    func testRunNowCompletesAndRecords() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let search = SearchEngine(server: conn)
        try await login(conn, server)
        let url = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let wish = WishlistEngine(server: conn, searchEngine: search, storeURL: url, interval: 9999, searchTimeout: 1)
        addTeardownBlock { await wish.shutdown(); await search.shutdown(); await conn.disconnect() }

        await wish.add("noresultsquery")
        let items = await wish.items
        await wish.runNow(items[0].id)
        let after = await wish.items
        XCTAssertNotNil(after[0].lastRun)
        XCTAssertEqual(after[0].lastResultCount, 0)
        // The wishlist search frame reached the server.
        let frame = try server.readFrame()
        XCTAssertEqual(frame.code, 103)
    }
}