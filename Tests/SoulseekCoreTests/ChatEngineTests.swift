import Foundation
import Darwin
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

final class ChatEngineTests: XCTestCase {
    private func login(_ conn: ServerConnection, _ server: FakeServer) async throws {
        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame()
        try server.send(loginSuccessFrame(greeting: "", ip: [127, 0, 0, 1], privileged: false))
        for _ in 0..<9 { _ = try server.readFrame() }
        await connecting
    }

    private func waitFor(_ engine: ChatEngine, timeout: TimeInterval = 8, where match: @escaping ([ChatEngine.Conversation]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await match(engine.conversations) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testPrivateMessageReceiveAndAutoAck() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        // Incoming PM (id 77, from alice).
        var w = MessageWriter()
        w.u32(77); w.u32(1_700_000_000); w.string("alice"); w.string("hey there"); w.u8(1)
        try server.send(w.frame(code: 22))

        let got = await waitFor(chat) { convs in
            convs.contains { $0.id == "pm:alice" && $0.messages.contains { $0.text == "hey there" && !$0.isMine } }
        }
        XCTAssertTrue(got, "PM conversation missing")

        // Server must receive the ack (code 23, id 77) or it resends forever.
        let ack = try server.readFrame()
        XCTAssertEqual(ack.code, 23)
        var ar = MessageReader(ack.payload)
        XCTAssertEqual(try ar.u32(), 77)
    }

    func testSendPrivateMessage() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        await chat.sendPrivateMessage(to: "alice", text: "hi alice")
        let frame = try server.readFrame()
        XCTAssertEqual(frame.code, 22)
        var r = MessageReader(frame.payload)
        XCTAssertEqual(try r.string(), "alice")
        XCTAssertEqual(try r.string(), "hi alice")

        let got = await waitFor(chat) { convs in
            convs.contains { $0.id == "pm:alice" && $0.messages.contains { $0.text == "hi alice" && $0.isMine } }
        }
        XCTAssertTrue(got, "own PM not recorded")
    }

    func testRoomJoinMembersAndSay() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        await chat.joinRoom("jazz")
        let join = try server.readFrame()
        XCTAssertEqual(join.code, 14)
        var jr = MessageReader(join.payload)
        XCTAssertEqual(try jr.string(), "jazz")
        XCTAssertEqual(try jr.u32(), 0)

        // JoinRoom reply fixture (2 members: alice/bob).
        try server.send(Data(hexString: "040000006a617a7a0200000005000000616c69636503000000626f6202000000020000000100000002000000e80300000500000000000000640000000a000000d00700000900000000000000c80000001400000002000000000000000100000002000000020000005553020000004445").framePayloadAsCode(14))
        let joined = await waitFor(chat) { convs in
            convs.contains { $0.id == "room:jazz" && $0.members.count == 2 }
        }
        XCTAssertTrue(joined, "room members missing")

        // Bob speaks; then we speak.
        var rw = MessageWriter()
        rw.string("jazz"); rw.string("bob"); rw.string("hi all")
        try server.send(rw.frame(code: 13))
        let heard = await waitFor(chat) { convs in
            convs.contains { $0.id == "room:jazz" && $0.messages.contains { $0.text == "hi all" && $0.sender == "bob" } }
        }
        XCTAssertTrue(heard, "room message missing")

        await chat.say(in: "jazz", text: "yo")
        let say = try server.readFrame()
        XCTAssertEqual(say.code, 13)
        var sr = MessageReader(say.payload)
        XCTAssertEqual(try sr.string(), "jazz")
        XCTAssertEqual(try sr.string(), "yo")
    }

    func testUserJoinLeaveUpdatesMembers() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        await chat.joinRoom("jazz")
        _ = try server.readFrame()
        try server.send(Data(hexString: "040000006a617a7a0200000005000000616c69636503000000626f6202000000020000000100000002000000e80300000500000000000000640000000a000000d00700000900000000000000c80000001400000002000000000000000100000002000000020000005553020000004445").framePayloadAsCode(14))
        _ = await waitFor(chat) { $0.contains { $0.id == "room:jazz" && $0.members.count == 2 } }

        // Carol joins (code 16 fixture).
        try server.send(Data(hexString: "040000006a617a7a050000006361726f6c02000000b80b000001000000000000002c0100001e00000000000000020000004652").framePayloadAsCode(16))
        let grew = await waitFor(chat) { $0.contains { $0.id == "room:jazz" && $0.members.count == 3 } }
        XCTAssertTrue(grew, "member join not tracked")

        // Bob leaves (code 17).
        var lw = MessageWriter()
        lw.string("jazz"); lw.string("bob")
        try server.send(lw.frame(code: 17))
        let shrank = await waitFor(chat) { $0.contains { $0.id == "room:jazz" && $0.members.count == 2 && !$0.members.contains { $0.username == "bob" } } }
        XCTAssertTrue(shrank, "member leave not tracked")
    }

    func testMusicCardShareToPM() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        let card = MusicCard(username: "alice", path: "@@music\\Album\\01 Song.flac", size: 123_456)
        await chat.shareMusic(card, to: "pm:alice")
        let frame = try server.readFrame()
        XCTAssertEqual(frame.code, 22)
        var r = MessageReader(frame.payload)
        XCTAssertEqual(try r.string(), "alice")
        let text = try r.string()
        XCTAssertEqual(MusicCard.parse(text), card)

        let got = await waitFor(chat) { convs in
            convs.contains { $0.id == "pm:alice" && $0.messages.contains { $0.card == card && $0.isMine } }
        }
        XCTAssertTrue(got, "card message not recorded")
    }

    func testRoomNameValidation() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        // Invalid names must not reach the wire (server rules: ASCII, ≤24,
        // no leading/trailing/consecutive spaces).
        await chat.joinRoom("  bad")
        await chat.joinRoom("way too long room name over limit")
        await chat.joinRoom("double  space")
        // Nothing to read: verify via a valid join arriving next.
        await chat.joinRoom("jazz")
        let join = try server.readFrame()
        XCTAssertEqual(join.code, 14)
        var jr = MessageReader(join.payload)
        XCTAssertEqual(try jr.string(), "jazz")
    }

    /// Room wall: 113 snapshot, 114 add, 115 remove, 116 set.
    func testRoomTickers() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        await chat.joinRoom("jazz")
        _ = try server.readFrame()
        try server.send(Data(hexString: "040000006a617a7a0200000005000000616c69636503000000626f6202000000020000000100000002000000e80300000500000000000000640000000a000000d00700000900000000000000c80000001400000002000000000000000100000002000000020000005553020000004445").framePayloadAsCode(14))
        _ = await waitFor(chat) { $0.contains { $0.id == "room:jazz" && $0.members.count == 2 } }

        // Snapshot (113): one ticker from alice.
        var snap = MessageWriter()
        snap.string("jazz")
        snap.u32(1)
        snap.string("alice")
        snap.string("welcome to jazz")
        try server.send(snap.frame(code: 113))
        let gotSnap = await waitFor(chat) { convs in
            convs.first { $0.id == "room:jazz" }?.tickers["alice"] == "welcome to jazz"
        }
        XCTAssertTrue(gotSnap, "ticker snapshot not applied")

        // Add (114): bob's ticker.
        var add = MessageWriter()
        add.string("jazz"); add.string("bob"); add.string("hello wall")
        try server.send(add.frame(code: 114))
        let gotAdd = await waitFor(chat) { convs in
            convs.first { $0.id == "room:jazz" }?.tickers["bob"] == "hello wall"
        }
        XCTAssertTrue(gotAdd, "ticker add not applied")

        // Remove (115): alice's ticker.
        var rem = MessageWriter()
        rem.string("jazz"); rem.string("alice")
        try server.send(rem.frame(code: 115))
        let gotRem = await waitFor(chat) { convs in
            convs.first { $0.id == "room:jazz" }?.tickers["alice"] == nil
        }
        XCTAssertTrue(gotRem, "ticker remove not applied")

        // Set (116): our own ticker goes out with room + message.
        await chat.setTicker(in: "jazz", message: "my ticker")
        let set = try server.readFrame()
        XCTAssertEqual(set.code, 116)
        var sr = MessageReader(set.payload)
        XCTAssertEqual(try sr.string(), "jazz")
        XCTAssertEqual(try sr.string(), "my ticker")
    }
}

private extension Data {
    init(hexString: String) {
        self.init(stride(from: 0, to: hexString.count, by: 2).map {
            UInt8(hexString.dropFirst($0).prefix(2), radix: 16)!
        })
    }

    /// Wrap a raw payload (hex fixtures include no frame header) as a server frame.
    func framePayloadAsCode(_ code: UInt32) -> Data {
        var w = MessageWriter()
        w.u32(UInt32(count) + 4)
        w.u32(code)
        return Data(w.bytes) + self
    }
}