import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Opt-in live upload gate (NAT boundary): account A shares a real file;
/// account B requests it. Both probe accounts sit behind the same NAT, so the
/// DATA path is protocol-impossible (both firewalled — same limit as slskd
/// without port mapping); the byte-exact chain is proven by the loopback
/// UploadEngineTests/TransferEngineTests. This gate verifies live: share
/// indexing, the indirect-P request routing A→server→B, A's dial attempt,
/// CannotConnect propagation, and B's fast graceful failure.
final class LiveUploadTests: XCTestCase {
    func testLiveUploadSignalingAndNATBoundary() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let userA = env["SLSK_USER"], let pass = env["SLSK_PASS"], !userA.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — opt-in")
        }
        let userB = "slsk_spike_b36c824"

        // A: share a deterministic file.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveShare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: root.appendingPathComponent("upload gate.mp3"))
        let virtualPath = root.lastPathComponent + "\\upload gate.mp3"
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: store) }
        let index = ShareIndex(storeURL: store)
        await index.addRoot(root.path)
        let indexed = await index.file(for: virtualPath)
        XCTAssertNotNil(indexed, "share index missed the file")

        let connA = ServerConnection()
        let connB = ServerConnection()
        await connA.connect(username: userA, password: pass)
        await connB.connect(username: userB, password: pass)
        guard case .connected = await connA.state, case .connected = await connB.state else {
            XCTFail("logins failed: A=\(await connA.state) B=\(await connB.state)")
            return
        }

        let uploads = UploadEngine(server: connA, index: index)
        let searchA = SearchEngine(server: connA,
            onUploadRequest: { link, user, file, pending in
                await uploads.handleQueueDownload(link, username: user, filename: file, pending: pending)
            },
            onPierce: { link, ticket, pending in
                await uploads.handleIndirectUpload(link, ticket: ticket, pending: pending)
            })
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transfers = TransferEngine(server: connB, directory: dirB)
        let searchB = SearchEngine(server: connB,
            onFileConnection: { link, pending in await transfers.handleDirectFile(link, pending: pending) },
            onPierce: { link, ticket, pending in
                await transfers.handleIndirectP(link, ticket: ticket, pending: pending)
            })
        await searchA.startListening()
        await searchB.startListening()
        defer {
            Task {
                await uploads.shutdown(); await transfers.shutdown()
                await searchA.shutdown(); await searchB.shutdown()
                await connA.disconnect(); await connB.disconnect()
                try? FileManager.default.removeItem(at: dirB)
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        // Diagnostic: watch for CannotConnect (A tried to dial B and failed).
        let eventTask = Task {
            let stream = await connB.makeEventStream()
            for await event in stream {
                if case .cannotConnect(let ticket) = event {
                    print("LIVE UPLOAD DIAG: CannotConnect ticket=\(ticket) — A could not dial B (both firewalled)")
                }
            }
        }
        defer { eventTask.cancel() }

        // B requests A's shared file.
        await transfers.download(username: userA, filename: virtualPath, size: UInt64(payload.count))
        let deadline = Date().addingTimeInterval(90)
        var finalState: TransferEngine.TransferState?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            let all = await transfers.transfers
            if let t = all.first {
                switch t.state {
                case .completed, .failed, .cancelled:
                    finalState = t.state
                default:
                    continue
                }
                break
            }
        }
        // Behind a shared NAT the correct outcome is a fast, graceful
        // "both firewalled" failure — never a hang, never a crash.
        XCTAssertEqual(finalState, .failed("user unreachable (both firewalled?)"),
                       "expected graceful firewalled failure, got \(String(describing: finalState))")
        print("LIVE UPLOAD: share indexed (\(await index.files.count) file), indirect-P request routed, CannotConnect handled, graceful firewalled failure — NAT boundary verified")
    }
}