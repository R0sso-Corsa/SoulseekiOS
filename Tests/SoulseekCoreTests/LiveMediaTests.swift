import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in LIVE media gate (AD-16): A registers a picture, sends the media
/// card by PM; B receives, parses, and fetches it over the transfer path.
/// Both probe accounts sit behind the same CGNAT, so the byte path may be
/// protocol-impossible (both firewalled — same limit as LiveUploadTests);
/// the acceptable outcomes are byte-exact completion OR the graceful
/// "both firewalled" failure. Never a hang. The byte-exact data path itself
/// is proven by the loopback media upload/download tests.
final class LiveMediaTests: XCTestCase {
    func testLiveMediaCardDeliveryAndFetch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let userA = env["SLSK_USER"], let pass = env["SLSK_PASS"], !userA.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — opt-in")
        }
        let userB = "slsk_spike_b36c824"

        // A: a deterministic "picture" registered as chat media.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMedia-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let media = Data((0..<120_000).map { UInt8(($0 * 13) % 251) })
        let fileURL = tmp.appendingPathComponent("gate-photo.jpg")
        try media.write(to: fileURL)
        let virtualPath = "ChatMedia\\gate-photo.jpg"
        let index = ShareIndex(storeURL: tmp.appendingPathComponent("shares.json"))
        await index.registerMedia(virtualPath: virtualPath, localPath: fileURL.path, size: UInt64(media.count))

        let connA = ServerConnection()
        let connB = ServerConnection()
        await connA.connect(username: userA, password: pass)
        await connB.connect(username: userB, password: pass)
        guard case .connected = await connA.state, case .connected = await connB.state else {
            XCTFail("logins failed"); return
        }
        let chatA = ChatEngine(server: connA)
        let chatB = ChatEngine(server: connB)
        let uploads = UploadEngine(server: connA, index: index)
        let searchA = SearchEngine(server: connA,
            onUploadRequest: { link, user, file, pending in
                await uploads.handleQueueDownload(link, username: user, filename: file, pending: pending)
            },
            onPierce: { link, ticket, pending in
                await uploads.handleIndirectUpload(link, ticket: ticket, pending: pending)
            })
        let dirB = tmp.appendingPathComponent("received")
        let transfers = TransferEngine(server: connB, directory: dirB, mediaDirectory: dirB)
        let searchB = SearchEngine(server: connB,
            onFileConnection: { link, pending in await transfers.handleDirectFile(link, pending: pending) },
            onPierce: { link, ticket, pending in
                await transfers.handleIndirectP(link, ticket: ticket, pending: pending)
            })
        await searchA.startListening()
        await searchB.startListening()
        defer {
            Task {
                await chatA.shutdown(); await chatB.shutdown()
                await uploads.shutdown(); await transfers.shutdown()
                await searchA.shutdown(); await searchB.shutdown()
                await connA.disconnect(); await connB.disconnect()
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        // A sends the media card by PM; B must receive + parse it.
        let card = MediaCard(username: userA, path: virtualPath, size: UInt64(media.count), kind: .image, ext: "jpg")
        await chatA.sendMedia(card, to: "pm:\(userB)")
        var gotCard = false
        let cardDeadline = Date().addingTimeInterval(20)
        while Date() < cardDeadline {
            let convs = await chatB.conversations
            if convs.contains(where: { $0.id == "pm:\(userA)" && $0.messages.contains { $0.media == card } }) {
                gotCard = true; break
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        guard gotCard else { XCTFail("B never received the media card"); return }
        print("LIVE MEDIA: card delivered A→B and parsed")

        // B fetches it via downloadMedia.
        await transfers.downloadMedia(username: card.username, filename: card.path, size: card.size)
        let deadline = Date().addingTimeInterval(90)
        var final: TransferEngine.Transfer?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            let all = await transfers.transfers
            if let t = all.first, t.state == .completed || t.state == .cancelled { final = t; break }
            if let t = all.first, case .failed = t.state { final = t; break }
        }
        let t = try XCTUnwrap(final, "media fetch hung — no terminal state in 90s")
        switch t.state {
        case .completed:
            let path = try XCTUnwrap(t.localPath)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), media, "media bytes differ")
            XCTAssertTrue(path.contains(dirB.lastPathComponent), "media landed outside the media dir")
            print("LIVE MEDIA: byte-exact fetch completed (\(media.count) bytes) — full live path verified")
        case .failed(let reason):
            XCTAssertEqual(reason, "user unreachable (both firewalled?)",
                           "unexpected failure reason: \(reason)")
            print("LIVE MEDIA: graceful both-firewalled failure (shared CGNAT) — signaling verified, data path loopback-proven")
        default:
            XCTFail("unexpected terminal state: \(t.state)")
        }
    }
}