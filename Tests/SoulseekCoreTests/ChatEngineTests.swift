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

    /// Full private-room suite: join reply with owner/operators, member and
    /// operator lists, invite/remove echoes, grant/revoke pushes, 1003 error.
    func testPrivateRoomSuite() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        // Create private room → JoinRoom type 1.
        await chat.joinRoom("vault", private: true)
        let join = try server.readFrame()
        XCTAssertEqual(join.code, 14)
        var jr = MessageReader(join.payload)
        XCTAssertEqual(try jr.string(), "vault")
        XCTAssertEqual(try jr.u32(), 1)
        try server.send(Data(hexString: "050000007661756c740100000003000000626f62010000000200000001000000e80300000500000000000000640000000a000000010000000000000001000000020000005553060000007465737465720100000005000000616c696365").framePayloadAsCode(14))
        let joined = await waitFor(chat) { convs in
            convs.contains { $0.id == "room:vault" && $0.isPrivate }
        }
        XCTAssertTrue(joined, "private join not applied")
        var conv = await chat.conversations.first { $0.id == "room:vault" }
        XCTAssertEqual(conv?.owner, "tester")
        XCTAssertEqual(conv?.operators, ["alice"])
        XCTAssertEqual(conv?.privateMembers, ["bob"])

        // RoomMembers(133) snapshot.
        var members = MessageWriter()
        members.string("vault"); members.u32(2); members.string("bob"); members.string("carol")
        try server.send(members.frame(code: 133))
        let gotMembers = await waitFor(chat) { $0.first { $0.id == "room:vault" }?.privateMembers == ["bob", "carol"] }
        XCTAssertTrue(gotMembers, "member list not applied")

        // Invite → 134 out, echo adds the member.
        await chat.invite("dave", to: "vault")
        let inv = try server.readFrame()
        XCTAssertEqual(inv.code, 134)
        var ir = MessageReader(inv.payload)
        XCTAssertEqual(try ir.string(), "vault")
        XCTAssertEqual(try ir.string(), "dave")
        var invEcho = MessageWriter()
        invEcho.string("vault"); invEcho.string("dave")
        try server.send(invEcho.frame(code: 134))
        let gotInvite = await waitFor(chat) { $0.first { $0.id == "room:vault" }?.privateMembers.contains("dave") == true }
        XCTAssertTrue(gotInvite, "invite echo not applied")

        // Make operator → 143 out, echo updates operators.
        await chat.makeOperator("bob", in: "vault")
        let op = try server.readFrame()
        XCTAssertEqual(op.code, 143)
        var opEcho = MessageWriter()
        opEcho.string("vault"); opEcho.string("bob")
        try server.send(opEcho.frame(code: 143))
        let gotOp = await waitFor(chat) { $0.first { $0.id == "room:vault" }?.operators.contains("bob") == true }
        XCTAssertTrue(gotOp, "operator echo not applied")

        // RoomOperators(148) replaces the list.
        var ops = MessageWriter()
        ops.string("vault"); ops.u32(1); ops.string("carol")
        try server.send(ops.frame(code: 148))
        let gotOps = await waitFor(chat) { $0.first { $0.id == "room:vault" }?.operators == ["carol"] }
        XCTAssertTrue(gotOps, "operator list not applied")

        // Remove member → 135 out, echo removes.
        await chat.removeMember("dave", from: "vault")
        let rem = try server.readFrame()
        XCTAssertEqual(rem.code, 135)
        var remEcho = MessageWriter()
        remEcho.string("vault"); remEcho.string("dave")
        try server.send(remEcho.frame(code: 135))
        let gotRem = await waitFor(chat) { $0.first { $0.id == "room:vault" }?.privateMembers.contains("dave") == false }
        XCTAssertTrue(gotRem, "remove echo not applied")

        // CantCreateRoom(1003) surfaces an error.
        var cant = MessageWriter()
        cant.string("taken")
        try server.send(cant.frame(code: 1003))
        var gotErr = false
        let errDeadline = Date().addingTimeInterval(5)
        while Date() < errDeadline {
            if await chat.roomError != nil { gotErr = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(gotErr, "1003 error not surfaced")

        // MembershipGranted(139) → auto-join sends JoinRoom type 1.
        var granted = MessageWriter()
        granted.string("otherroom")
        try server.send(granted.frame(code: 139))
        let autoJoin = try server.readFrame()
        XCTAssertEqual(autoJoin.code, 14)
        var ajr = MessageReader(autoJoin.payload)
        XCTAssertEqual(try ajr.string(), "otherroom")
        XCTAssertEqual(try ajr.u32(), 1)

        // MembershipRevoked(140) removes the conversation.
        var revoked = MessageWriter()
        revoked.string("vault")
        try server.send(revoked.frame(code: 140))
        let gotRevoked = await waitFor(chat) { !$0.contains { $0.id == "room:vault" } }
        XCTAssertTrue(gotRevoked, "revocation did not remove the room")
    }

    /// "Create private" with a name that already exists as a PUBLIC room:
    /// the server replies with a public join (no owner) — must surface an
    /// error + in-room warning instead of silently showing a public room.
    func testPrivateCreateCollisionWithPublicRoom() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        await chat.joinRoom("jazz", private: true)
        let join = try server.readFrame()
        XCTAssertEqual(join.code, 14)
        var jr = MessageReader(join.payload)
        XCTAssertEqual(try jr.string(), "jazz")
        XCTAssertEqual(try jr.u32(), 1)
        // Public join reply (no owner suffix).
        try server.send(Data(hexString: "040000006a617a7a0200000005000000616c69636503000000626f6202000000020000000100000002000000e80300000500000000000000640000000a000000d00700000900000000000000c80000001400000002000000000000000100000002000000020000005553020000004445").framePayloadAsCode(14))
        let warned = await waitFor(chat) { convs in
            convs.contains { $0.id == "room:jazz" && $0.messages.contains { $0.text.contains("PUBLIC") } }
        }
        XCTAssertTrue(warned, "collision warning missing")
        let err = await chat.roomError
        XCTAssertNotNil(err, "roomError not set on private-create collision")
        let conv = await chat.conversations.first { $0.id == "room:jazz" }
        XCTAssertEqual(conv?.isPrivate, false)
    }

    /// Chats survive an engine restart (app relaunch): PM history + room
    /// state restore from disk, and rejoinRooms re-sends JoinRoom with the
    /// persisted room type.
    func testChatPersistenceAndRejoin() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-persist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }

        // Session 1: receive a PM, join a private room, send a PM.
        let server1 = try FakeServer()
        defer { server1.close() }
        let conn1 = ServerConnection()
        let chat1 = ChatEngine(server: conn1, storeURL: store)
        try await login(conn1, server1)

        var pm = MessageWriter()
        pm.u32(77)
        pm.u32(UInt32(Date().timeIntervalSince1970))
        pm.string("alice")
        pm.string("hello persist")
        pm.u8(1)
        try server1.send(pm.frame(code: 22))
        let gotPM = await waitFor(chat1) { $0.contains { $0.id == "pm:alice" } }
        XCTAssertTrue(gotPM, "PM not received")
        _ = try server1.readFrame() // MessageAcked(23)

        await chat1.joinRoom("vault", private: true)
        _ = try server1.readFrame() // JoinRoom
        try server1.send(Data(hexString: "050000007661756c740100000003000000626f62010000000200000001000000e80300000500000000000000640000000a000000010000000000000001000000020000005553060000007465737465720100000005000000616c696365").framePayloadAsCode(14))
        let gotRoom = await waitFor(chat1) { $0.contains { $0.id == "room:vault" && $0.isPrivate } }
        XCTAssertTrue(gotRoom, "private room not joined")

        await chat1.sendPrivateMessage(to: "alice", text: "my reply")
        _ = try server1.readFrame() // MessageUser(22)
        await chat1.shutdown() // flushes the save
        await conn1.disconnect()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path), "history file not written")

        // Session 2: fresh engine + connection, same store file.
        let server2 = try FakeServer()
        defer { server2.close() }
        let conn2 = ServerConnection()
        let chat2 = ChatEngine(server: conn2, storeURL: store)
        try await login(conn2, server2)
        addTeardownBlock { await chat2.shutdown(); await conn2.disconnect() }

        let restored = await chat2.conversations
        let pmConv = restored.first { $0.id == "pm:alice" }
        XCTAssertNotNil(pmConv, "PM conversation lost")
        XCTAssertTrue(pmConv?.messages.contains { $0.text == "hello persist" && $0.serverID == 77 } == true,
                      "received PM history lost")
        XCTAssertTrue(pmConv?.messages.contains { $0.text == "my reply" && $0.isMine } == true,
                      "sent PM history lost")
        let roomConv = restored.first { $0.id == "room:vault" }
        XCTAssertEqual(roomConv?.isPrivate, true, "private flag lost")
        XCTAssertEqual(roomConv?.owner, "tester", "owner lost")
        XCTAssertEqual(roomConv?.operators, ["alice"], "operators lost")

        // Rejoin sends JoinRoom with the persisted type (1 = private).
        await chat2.rejoinRooms()
        let rejoin = try server2.readFrame()
        XCTAssertEqual(rejoin.code, 14)
        var rr = MessageReader(rejoin.payload)
        XCTAssertEqual(try rr.string(), "vault")
        XCTAssertEqual(try rr.u32(), 1)
    }

    /// Invited while OFFLINE (e.g. from a desktop client): the membership
    /// shows up in RoomList's private arrays on next login — the engine must
    /// auto-join those rooms so they appear in Chat without manual steps.
    func testOfflineInviteAutoJoinsFromRoomList() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        // RoomList(64): no public/owned rooms, one private membership.
        try server.send(Data(hexString: "000000000000000000000000000000000100000007000000696e7669746564010000000200000000000000").framePayloadAsCode(64))
        let join = try server.readFrame()
        XCTAssertEqual(join.code, 14, "engine did not auto-join the invited room")
        var jr = MessageReader(join.payload)
        XCTAssertEqual(try jr.string(), "invited")
        XCTAssertEqual(try jr.u32(), 1, "must join as private")

        // Private join reply → conversation appears.
        try server.send(Data(hexString: "07000000696e76697465640100000003000000626f62010000000200000001000000e80300000500000000000000640000000a000000010000000000000001000000020000005553060000007465737465720100000005000000616c696365").framePayloadAsCode(14))
        let joined = await waitFor(chat) { $0.contains { $0.id == "room:invited" && $0.isPrivate } }
        XCTAssertTrue(joined, "invited room never appeared in conversations")

        // A second RoomList must NOT re-join rooms we're already in.
        try server.send(Data(hexString: "000000000000000000000000000000000100000007000000696e7669746564010000000200000000000000").framePayloadAsCode(64))
        // Give the engine a moment; no new JoinRoom may be sent.
        try await Task.sleep(nanoseconds: 300_000_000)
        // readFrame would block if nothing was sent — use a short-read probe:
        // FakeServer.readFrame blocks, so instead verify via a follow-up
        // explicit action: send a PM and expect ONLY that frame next.
        await chat.sendPrivateMessage(to: "bob", text: "ping")
        let next = try server.readFrame()
        XCTAssertEqual(next.code, 22, "unexpected extra frame (duplicate auto-join?)")
    }

    /// Rejoining a room (reconnect) must PRESERVE its message history and
    /// not spam duplicate "Joined" notes on consecutive rejoins.
    func testRejoinPreservesHistory() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        let fixture = Data(hexString: "040000006a617a7a0200000005000000616c69636503000000626f6202000000020000000100000002000000e80300000500000000000000640000000a000000d00700000900000000000000c80000001400000002000000000000000100000002000000020000005553020000004445")
        await chat.joinRoom("jazz")
        _ = try server.readFrame()
        try server.send(fixture.framePayloadAsCode(14))
        let joined = await waitFor(chat) { $0.contains { $0.id == "room:jazz" } }
        XCTAssertTrue(joined)

        // A chat message arrives (server echo of SayChatroom).
        var say = MessageWriter()
        say.string("jazz"); say.string("alice"); say.string("old message")
        try server.send(say.frame(code: 13))
        let gotMsg = await waitFor(chat) {
            $0.first { $0.id == "room:jazz" }?.messages.contains { $0.text == "old message" } == true
        }
        XCTAssertTrue(gotMsg, "chat message missing")

        // Rejoin twice (two reconnects).
        for _ in 0..<2 {
            await chat.rejoinRooms()
            let rj = try server.readFrame()
            XCTAssertEqual(rj.code, 14)
            try server.send(fixture.framePayloadAsCode(14))
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let conv = await chat.conversations.first { $0.id == "room:jazz" }
        XCTAssertTrue(conv?.messages.contains { $0.text == "old message" } == true,
                      "history lost on rejoin")
        let joinNotes = conv?.messages.filter { $0.text == "Joined jazz" }.count ?? 0
        XCTAssertEqual(joinNotes, 1, "rejoins must be silent — only the FIRST join gets a note")
    }

    /// Reconnect noise: our own join/leave echoes (server broadcasts them to
    /// us too) must not produce "<me> joined/left" notes, and rejoining an
    /// existing room must not re-add "Joined X".
    func testReconnectJoinNotesAreSilent() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server) // username "tester"
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        let fixture = Data(hexString: "040000006a617a7a0200000005000000616c69636503000000626f6202000000020000000100000002000000e80300000500000000000000640000000a000000d00700000900000000000000c80000001400000002000000000000000100000002000000020000005553020000004445")
        await chat.joinRoom("jazz")
        _ = try server.readFrame()
        try server.send(fixture.framePayloadAsCode(14))
        _ = await waitFor(chat) { $0.contains { $0.id == "room:jazz" } }

        // Our OWN join echo (16) — no "tester joined" note allowed.
        var ownJoin = MessageWriter()
        ownJoin.string("jazz"); ownJoin.string("tester")
        ownJoin.u32(2); ownJoin.u32(3000); ownJoin.u32(1); ownJoin.u32(0)
        ownJoin.u32(300); ownJoin.u32(30); ownJoin.u32(0); ownJoin.string("US")
        try server.send(ownJoin.frame(code: 16))
        // Someone else joins — note IS allowed.
        try server.send(Data(hexString: "040000006a617a7a050000006361726f6c02000000b80b000001000000000000002c0100001e00000000000000020000004652").framePayloadAsCode(16))
        let carolNoted = await waitFor(chat) {
            $0.first { $0.id == "room:jazz" }?.messages.contains { $0.text == "carol joined" } == true
        }
        XCTAssertTrue(carolNoted, "other users' joins should still be noted")
        // Our OWN leave echo (17) — no "tester left" note allowed.
        var ownLeave = MessageWriter()
        ownLeave.string("jazz"); ownLeave.string("tester")
        try server.send(ownLeave.frame(code: 17))
        try await Task.sleep(nanoseconds: 300_000_000)

        // Rejoin — no second "Joined jazz".
        await chat.rejoinRooms()
        _ = try server.readFrame()
        try server.send(fixture.framePayloadAsCode(14))
        try await Task.sleep(nanoseconds: 300_000_000)

        let conv = await chat.conversations.first { $0.id == "room:jazz" }
        let texts = conv?.messages.map(\.text) ?? []
        XCTAssertFalse(texts.contains("tester joined"), "own join echo must be silent")
        XCTAssertFalse(texts.contains("tester left"), "own leave echo must be silent")
        XCTAssertEqual(texts.filter { $0 == "Joined jazz" }.count, 1, "rejoin must not re-note")
    }

    /// AD-16: sendMedia goes out as the slsk-media text line (PM 22 / room 13)
    /// and incoming lines parse into ChatMessage.media.
    func testMediaCardSendAndReceive() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let chat = ChatEngine(server: conn)
        try await login(conn, server)
        addTeardownBlock { await chat.shutdown(); await conn.disconnect() }

        let card = MediaCard(username: "tester", path: "ChatMedia\\x.jpg", size: 99, kind: .image, ext: "jpg")
        await chat.sendMedia(card, to: "pm:alice")
        let pm = try server.readFrame()
        XCTAssertEqual(pm.code, 22)
        var pr = MessageReader(pm.payload)
        XCTAssertEqual(try pr.string(), "alice")
        let sentText = try pr.string()
        XCTAssertTrue(sentText.hasPrefix("slsk-media:"))
        XCTAssertEqual(MediaCard.parse(sentText), card)
        // Local echo carries the parsed media card.
        let mine = await waitFor(chat) {
            $0.first { $0.id == "pm:alice" }?.messages.contains { $0.media == card && $0.isMine } == true
        }
        XCTAssertTrue(mine, "sent media not rendered locally")

        // Incoming room media line parses.
        var say = MessageWriter()
        say.string("jazz"); say.string("bob")
        say.string(MediaCard(username: "bob", path: "ChatMedia\\v.mp4", size: 5000, kind: .video, ext: "mp4").encoded())
        try server.send(say.frame(code: 13))
        let got = await waitFor(chat) {
            $0.first { $0.id == "room:jazz" }?.messages.contains { $0.media?.kind == .video && $0.sender == "bob" } == true
        }
        XCTAssertTrue(got, "incoming media card not parsed")
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