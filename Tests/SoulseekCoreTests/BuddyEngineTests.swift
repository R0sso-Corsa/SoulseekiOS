import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

final class BuddyEngineTests: XCTestCase {
    private func login(_ conn: ServerConnection, _ server: FakeServer) async throws {
        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame()
        try server.send(loginSuccessFrame(greeting: "", ip: [127, 0, 0, 1], privileged: false))
        for _ in 0..<9 { _ = try server.readFrame() }
        await connecting
    }

    private func watchReply(_ username: String, status: UInt32) -> Data {
        var w = MessageWriter()
        w.string(username)
        w.u8(1)
        w.u32(status)
        w.u32(1000) // speed
        w.u32(5)    // uploads
        w.u32(0)    // unknown
        w.u32(100)  // files
        w.u32(10)   // folders
        w.string("GB")
        return w.frame(code: 5)
    }

    func testAddWatchStatusPushAndRemove() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("buddies.json")

        let conn = ServerConnection()
        let engine = BuddyEngine(server: conn, storeURL: store)
        addTeardownBlock { await engine.shutdown(); await conn.disconnect() }
        try await login(conn, server)

        // Add → WatchUser(5) sent; reply populates stats.
        async let adding: Void = engine.add("alice")
        let watch = try server.readFrame()
        XCTAssertEqual(watch.code, 5)
        var wr = MessageReader(watch.payload)
        XCTAssertEqual(try wr.string(), "alice")
        try server.send(watchReply("alice", status: 2))
        try await adding
        var buddies = await engine.buddies
        XCTAssertEqual(buddies.count, 1)
        XCTAssertEqual(buddies[0].status, .online)
        XCTAssertEqual(buddies[0].files, 100)
        XCTAssertEqual(buddies[0].country, "GB")

        // Status push (7) updates the buddy without a new request.
        var push = MessageWriter()
        push.string("alice")
        push.u32(1) // away
        push.u8(0)
        try server.send(push.frame(code: 7))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            buddies = await engine.buddies
            if buddies[0].status == .away { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(buddies[0].status, .away, "status push not applied")

        // Remove → UnwatchUser(6), list empty, persisted.
        async let removing: Void = engine.remove("alice")
        let unwatch = try server.readFrame()
        XCTAssertEqual(unwatch.code, 6)
        try await removing
        buddies = await engine.buddies
        XCTAssertTrue(buddies.isEmpty)

        // Persistence: add again, then a fresh engine loads the name.
        async let adding2: Void = engine.add("bob")
        _ = try server.readFrame()
        try server.send(watchReply("bob", status: 2))
        try await adding2
        let engine2 = BuddyEngine(server: conn, storeURL: store)
        addTeardownBlock { await engine2.shutdown() }
        let loaded = await engine2.buddies
        XCTAssertEqual(loaded.map(\.username), ["bob"])
    }
}