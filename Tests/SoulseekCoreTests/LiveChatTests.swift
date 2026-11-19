import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in live chat gate with TWO throwaway accounts (B auto-registers on
/// first login): PM delivery + ack, group-room creation, membership events,
/// and a music card posted in the room that the recipient parses AND
/// downloads via the normal transfer flow. Never touches real users.
final class LiveChatTests: XCTestCase {
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

    func testLivePMRoomAndMusicCard() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let userA = env["SLSK_USER"], let pass = env["SLSK_PASS"], !userA.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live chat test is opt-in")
        }

        let connA = ServerConnection()
        let connB = ServerConnection()
        let okA = await login(connA, username: userA, password: pass)
        let okB = await login(connB, username: userB, password: pass)
        XCTAssertTrue(okA, "A login failed")
        XCTAssertTrue(okB, "B login failed")
        let chatA = ChatEngine(server: connA)
        let chatB = ChatEngine(server: connB)
        defer {
            Task {
                await chatA.shutdown(); await chatB.shutdown()
                await connA.disconnect(); await connB.disconnect()
            }
        }

        // 1. Private message A → B.
        await chatA.sendPrivateMessage(to: userB, text: "hello from the iOS client test")
        let gotPM = await waitFor(chatB, timeout: 20) { convs in
            convs.contains { $0.id == "pm:\(userA)" && $0.messages.contains { $0.text == "hello from the iOS client test" } }
        }
        XCTAssertTrue(gotPM, "B never received the PM")
        print("LIVE CHAT: PM delivered A→B")

        // 2. A creates a group room (JoinRoom creates nonexistent rooms).
        let room = "SlskIosTest" + String(UInt32.random(in: 100...999))
        await chatA.joinRoom(room)
        let aJoined = await waitFor(chatA, timeout: 20) { $0.contains { $0.id == "room:\(room)" } }
        XCTAssertTrue(aJoined, "A never joined its own room")
        await chatB.joinRoom(room)
        let bJoined = await waitFor(chatB, timeout: 20) { $0.contains { $0.id == "room:\(room)" && $0.members.contains { $0.username == userA } } }
        XCTAssertTrue(bJoined, "B never joined the room")
        let aSawB = await waitFor(chatA, timeout: 20) { $0.contains { $0.id == "room:\(room)" && $0.members.contains { $0.username == self.userB } } }
        XCTAssertTrue(aSawB, "A never saw B join")
        print("LIVE CHAT: room \(room) created, both members present")

        // 3. Find a real downloadable file to share as a music card.
        let search = SearchEngine(server: connA)
        await search.startListening()
        try await Task.sleep(nanoseconds: 500_000_000)
        await search.search("mp3", timeout: 15)
        let searchDeadline = Date().addingTimeInterval(20)
        var searchState = await search.state
        while Date() < searchDeadline && !searchState.finished {
            try await Task.sleep(nanoseconds: 500_000_000)
            searchState = await search.state
        }
        var card: MusicCard?
        for reply in searchState.replies where reply.freeSlots {
            if let f = reply.files.first(where: { $0.ext == "mp3" && $0.size >= 300_000 && $0.size <= 4_000_000 && ($0.bitrate != nil || $0.duration != nil) }) {
                card = MusicCard(username: reply.username, path: f.path, size: f.size)
                break
            }
        }
        let sharedCard = try XCTUnwrap(card, "no downloadable candidate found for the music card")

        // 4. A posts the card in the room; B receives and parses it.
        await chatA.shareMusic(sharedCard, to: "room:\(room)")
        let bGotCard = await waitFor(chatB, timeout: 20) { convs in
            convs.contains { $0.id == "room:\(room)" && $0.messages.contains { $0.card == sharedCard } }
        }
        XCTAssertTrue(bGotCard, "B never received the music card")
        print("LIVE CHAT: music card delivered in room: \(sharedCard.username) / \(sharedCard.title)")

        // 5. B downloads the shared file via the normal transfer flow.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transfers = TransferEngine(server: connB, directory: dir)
        await transfers.download(username: sharedCard.username, filename: sharedCard.path, size: sharedCard.size)
        let dlDeadline = Date().addingTimeInterval(90)
        var completed: TransferEngine.Transfer?
        while Date() < dlDeadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let all = await transfers.transfers
            if let done = all.first(where: { $0.state == .completed }) { completed = done; break }
            if all.allSatisfy({ t in if case .failed = t.state { return true }; return t.state == .cancelled }) { break }
        }
        let finalStates = await transfers.transfers.map { "\($0.state)" }
        let t = try XCTUnwrap(completed, "card download did not complete: \(finalStates)")
        let path = try XCTUnwrap(t.localPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attrs[.size] as? UInt64, sharedCard.size)
        print("LIVE CHAT: B downloaded the shared music (\(sharedCard.size) bytes) — full send-music flow verified")

        // 6. Clean up: leave the room.
        await chatA.leaveRoom(room)
        await chatB.leaveRoom(room)
        await transfers.shutdown()
        await search.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }
}