import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in probe: does a freshly created room appear in the server's RoomList?
final class LiveRoomListTests: XCTestCase {
    func testCreatedRoomAppearsInRoomList() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set")
        }
        let conn = ServerConnection()
        await conn.connect(username: user, password: pass)
        guard case .connected = await conn.state else { XCTFail("login failed"); return }
        let chat = ChatEngine(server: conn)

        let room = "SlskProbe\(Int.random(in: 1000...9999))"
        await chat.joinRoom(room)
        let joined = await waitForRoom(chat, room: room)
        XCTAssertTrue(joined, "did not join created room")
        print("LIVE ROOMLIST: created \(room)")

        await chat.requestRoomList()
        let deadline = Date().addingTimeInterval(15)
        var list: RoomList?
        while Date() < deadline {
            list = await chat.roomList
            if list != nil { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let l = try XCTUnwrap(list, "no room list received")
        let names = l.publicRooms.map(\.name)
        print("LIVE ROOMLIST: \(names.count) public rooms; contains created room: \(names.contains(room))")
        let counts = l.publicRooms.map(\.userCount)
        print("LIVE ROOMLIST: min users=\(counts.min() ?? 0) max=\(counts.max() ?? 0)")
        let small = l.publicRooms.filter { $0.userCount <= 2 }.prefix(5)
        print("LIVE ROOMLIST: sample small rooms: \(small.map { "\($0.name)(\($0.userCount))" })")
        await chat.shutdown()
        await conn.disconnect()
    }

    private func waitForRoom(_ chat: ChatEngine, room: String) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await chat.conversations.contains(where: { $0.id == "room:\(room)" }) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}