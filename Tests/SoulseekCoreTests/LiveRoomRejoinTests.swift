import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in probe: rejoining an existing private room with type 0 (public join,
/// what the room browser used) vs type 1 — does the server reply?
final class LiveRoomRejoinTests: XCTestCase {
    func testRejoinPrivateRoomWithType0() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set")
        }
        let room = "SlskRe" + String(Int.random(in: 1000...9999))

        // Session 1: create the private room.
        let conn1 = ServerConnection()
        await conn1.connect(username: user, password: pass)
        guard case .connected = await conn1.state else { XCTFail("login 1 failed"); return }
        let chat1 = ChatEngine(server: conn1)
        await chat1.setInvitationsEnabled(true)
        await chat1.joinRoom(room, private: true)
        var created = false
        let d1 = Date().addingTimeInterval(15)
        while Date() < d1 {
            if await chat1.conversations.contains(where: { $0.id == "room:\(room)" && $0.isPrivate }) { created = true; break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertTrue(created, "private room not created")
        print("LIVE REJOIN: created \(room)")
        await chat1.shutdown()
        await conn1.disconnect()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Session 2: rejoin with TYPE 0 (the browser's old behavior).
        let conn2 = ServerConnection()
        await conn2.connect(username: user, password: pass)
        guard case .connected = await conn2.state else { XCTFail("login 2 failed"); return }
        let chat2 = ChatEngine(server: conn2)
        await chat2.joinRoom(room, private: false)
        var got0 = false
        let d2 = Date().addingTimeInterval(8)
        while Date() < d2 {
            if await chat2.conversations.contains(where: { $0.id == "room:\(room)" }) { got0 = true; break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let conv0 = await chat2.conversations.first { $0.id == "room:\(room)" }
        print("LIVE REJOIN: type0 reply=\(got0) isPrivate=\(conv0?.isPrivate ?? false) owner=\(conv0?.owner ?? "nil")")

        // Now TYPE 1.
        await chat2.joinRoom(room, private: true)
        var got1 = false
        let d3 = Date().addingTimeInterval(8)
        while Date() < d3 {
            if let c = await chat2.conversations.first(where: { $0.id == "room:\(room)" }), c.isPrivate { got1 = true; break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let conv1 = await chat2.conversations.first { $0.id == "room:\(room)" }
        print("LIVE REJOIN: type1 isPrivate=\(got1) owner=\(conv1?.owner ?? "nil")")

        // Cleanup.
        await chat2.cancelOwnership(of: room)
        await chat2.leavePrivateRoom(room)
        await chat2.shutdown()
        await conn2.disconnect()
    }

    /// What happens when "Create private group" uses a name that already
    /// exists as a PUBLIC room? Does the server convert it or join as public?
    func testPrivateCreateOverExistingPublicName() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set")
        }
        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else { XCTFail("login failed"); return }
        let chat = ChatEngine(server: conn)
        let room = "SlskPub" + String(Int.random(in: 1000...9999))

        // Create as PUBLIC first.
        await chat.joinRoom(room, private: false)
        var gotPublic = false
        let d1 = Date().addingTimeInterval(12)
        while Date() < d1 {
            if await chat.conversations.contains(where: { $0.id == "room:\(room)" }) { gotPublic = true; break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertTrue(gotPublic, "public room not created")
        let pub = await chat.conversations.first { $0.id == "room:\(room)" }
        print("LIVE COLLIDE: public created isPrivate=\(pub?.isPrivate ?? false)")
        await chat.leaveRoom(room)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Now "create private" with the SAME name.
        await chat.joinRoom(room, private: true)
        var isPriv = false
        let d2 = Date().addingTimeInterval(10)
        while Date() < d2 {
            if let c = await chat.conversations.first(where: { $0.id == "room:\(room)" }), c.isPrivate { isPriv = true; break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let c2 = await chat.conversations.first { $0.id == "room:\(room)" }
        let collideErr = await chat.roomError
        print("LIVE COLLIDE: after type1 join isPrivate=\(isPriv) owner=\(c2?.owner ?? "nil") roomError=\(collideErr ?? "nil")")
        XCTAssertFalse(isPriv, "server should NOT convert a public room to private")
        XCTAssertNotNil(collideErr, "app must surface the collision error")
        await chat.shutdown()
        await conn.disconnect()
    }
}