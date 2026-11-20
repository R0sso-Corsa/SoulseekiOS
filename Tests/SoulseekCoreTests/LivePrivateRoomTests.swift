import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in LIVE private-room gate with two throwaway accounts: A creates a
/// private room, invites B (B auto-joins via MembershipGranted), promotes B
/// to operator, then removes B (MembershipRevoked). Never touches real users.
final class LivePrivateRoomTests: XCTestCase {
    private let userB = "slsk_spike_b36c824"

    private func login(_ conn: ServerConnection, username: String, password: String) async -> Bool {
        await conn.connect(username: username, password: password)
        if case .connected = await conn.state { return true }
        return false
    }

    private func waitFor(_ chat: ChatEngine, timeout: TimeInterval, where match: @escaping ([ChatEngine.Conversation]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await match(chat.conversations) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    func testLivePrivateRoomInviteAndOperators() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let userA = env["SLSK_USER"], let pass = env["SLSK_PASS"], !userA.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live private-room test is opt-in")
        }

        let connA = ServerConnection()
        let connB = ServerConnection()
        let okA = await login(connA, username: userA, password: pass)
        let okB = await login(connB, username: userB, password: pass)
        XCTAssertTrue(okA, "A login failed")
        XCTAssertTrue(okB, "B login failed")
        let chatA = ChatEngine(server: connA)
        let chatB = ChatEngine(server: connB)
        // The server only delivers MembershipGranted when invitations are on.
        await chatA.setInvitationsEnabled(true)
        await chatB.setInvitationsEnabled(true)
        defer {
            Task {
                await chatA.shutdown(); await chatB.shutdown()
                await connA.disconnect(); await connB.disconnect()
            }
        }

        // 1. A creates a PRIVATE room.
        let room = "SlskPriv" + String(UInt32.random(in: 1000...9999))
        await chatA.joinRoom(room, private: true)
        let aJoined = await waitFor(chatA, timeout: 20) { convs in
            convs.contains { $0.id == "room:\(room)" && $0.isPrivate && $0.owner == userA }
        }
        let aConvs = await chatA.conversations.map(\.id)
        guard aJoined else { XCTFail("A did not create the private room: \(aConvs)"); return }
        print("LIVE PRIVATE: A created private room \(room)")

        // 2. A invites B → B receives MembershipGranted and auto-joins.
        await chatA.invite(userB, to: room)
        let bJoined = await waitFor(chatB, timeout: 25) { convs in
            convs.contains { $0.id == "room:\(room)" && $0.isPrivate }
        }
        guard bJoined else { XCTFail("B never auto-joined after the invite"); return }
        print("LIVE PRIVATE: B invited and auto-joined")

        // 3. A promotes B to operator → B receives OperatorshipGranted.
        await chatA.makeOperator(userB, in: room)
        let bOp = await waitFor(chatB, timeout: 20) { convs in
            convs.contains { $0.id == "room:\(room)" && $0.operators.contains(self.userB) }
        }
        guard bOp else { XCTFail("B never received operator abilities"); return }
        print("LIVE PRIVATE: B promoted to operator")

        // 4. A removes B → B receives MembershipRevoked, room disappears.
        await chatA.removeMember(userB, from: room)
        let bRemoved = await waitFor(chatB, timeout: 20) { convs in
            !convs.contains { $0.id == "room:\(room)" }
        }
        guard bRemoved else { XCTFail("B's room was not removed after revocation"); return }
        print("LIVE PRIVATE: B removed, room revoked — full suite verified")

        // Cleanup: A cancels ownership + membership so the room doesn't linger.
        await chatA.cancelOwnership(of: room)
        await chatA.leavePrivateRoom(room)
    }

    /// Membership resolution on reconnect: B is invited while ONLINE (the
    /// server drops invites to offline users — live-probed), joins, then
    /// restarts with a FRESH engine (no persisted history, like a reinstall
    /// or a room joined on desktop). The RoomList private arrays must carry
    /// the membership and the engine must auto-join it.
    func testLiveMembershipResolvesOnReconnect() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let userA = env["SLSK_USER"], let pass = env["SLSK_PASS"], !userA.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live private-room test is opt-in")
        }

        // A creates a private room; B connects and is invited while online.
        let connA = ServerConnection()
        let okA = await login(connA, username: userA, password: pass)
        XCTAssertTrue(okA, "A login failed")
        let chatA = ChatEngine(server: connA)
        await chatA.setInvitationsEnabled(true)
        let room = "SlskRes" + String(UInt32.random(in: 1000...9999))
        await chatA.joinRoom(room, private: true)
        let aJoined = await waitFor(chatA, timeout: 20) { $0.contains { $0.id == "room:\(room)" && $0.isPrivate } }
        guard aJoined else { XCTFail("A did not create the private room"); return }

        let connB1 = ServerConnection()
        let chatB1 = ChatEngine(server: connB1)
        let okB1 = await login(connB1, username: userB, password: pass)
        XCTAssertTrue(okB1, "B login failed")
        await chatB1.setInvitationsEnabled(true)
        // Let the server process EnableRoomInvitations before the invite —
        // 134 racing ahead of 141 gets dropped (invitations default OFF).
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await chatA.invite(userB, to: room)
        let bJoined = await waitFor(chatB1, timeout: 25) { $0.contains { $0.id == "room:\(room)" && $0.isPrivate } }
        guard bJoined else { XCTFail("B never joined via online invite"); return }
        print("LIVE RESOLVE: B joined via online invite")
        // B "closes the app" — engine gone, no persisted history.
        await chatB1.shutdown()
        await connB1.disconnect()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // B reconnects with a FRESH engine — RoomList must resolve the room.
        let connB2 = ServerConnection()
        let chatB2 = ChatEngine(server: connB2)
        let okB2 = await login(connB2, username: userB, password: pass)
        XCTAssertTrue(okB2, "B relogin failed")
        await chatB2.requestRoomList()
        let bResolved = await waitFor(chatB2, timeout: 30) { $0.contains { $0.id == "room:\(room)" && $0.isPrivate } }
        let bList = await chatB2.roomList
        print("LIVE RESOLVE: B privateRooms=\(bList?.privateRooms.map(\.name) ?? []) resolved=\(bResolved)")
        await chatB2.shutdown()
        await connB2.disconnect()
        await chatA.cancelOwnership(of: room)
        await chatA.leavePrivateRoom(room)
        await chatA.shutdown()
        await connA.disconnect()
        guard bResolved else { XCTFail("membership did not resolve on reconnect"); return }
        print("LIVE RESOLVE: membership auto-resolved on reconnect — no manual step")
    }
}