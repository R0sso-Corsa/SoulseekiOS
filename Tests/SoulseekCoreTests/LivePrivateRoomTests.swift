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
}