import Foundation
import Darwin
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

final class TransferEngineTests: XCTestCase {
    private func waitForTransfer(_ engine: TransferEngine, timeout: TimeInterval = 8, where match: @escaping (TransferEngine.Transfer) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await engine.transfers.contains(where: match) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func login(_ conn: ServerConnection, _ server: FakeServer) async throws {
        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame()
        try server.send(loginSuccessFrame(greeting: "", ip: [127, 0, 0, 1], privileged: false))
        for _ in 0..<9 { _ = try server.readFrame() }
        await connecting
    }

    private func sendAddressReply(_ server: FakeServer, username: String, port: UInt16) throws {
        let req = try server.readFrame()
        XCTAssertEqual(req.code, 3)
        var r = MessageReader(req.payload)
        XCTAssertEqual(try r.string(), username)
        var w = MessageWriter()
        w.string(username)
        w.u8(1); w.u8(0); w.u8(0); w.u8(127) // 127.0.0.1
        w.u32(UInt32(port))
        w.u32(0); w.u8(0); w.u8(0) // no obfuscation (amount u32 + port u16)
        try server.send(w.frame(code: 3))
    }

    private func sendConnectToF(_ server: FakeServer, username: String, port: UInt16, ticket: UInt32) throws {
        var w = MessageWriter()
        w.string(username); w.string("F")
        w.u8(1); w.u8(0); w.u8(0); w.u8(127)
        w.u32(UInt32(port)); w.u32(ticket); w.u8(0)
        w.u32(0); w.u32(0)
        try server.send(w.frame(code: 18))
    }

    /// Full indirect download: GetPeerAddress → P dial + PeerInit → QueueDownload →
    /// TransferRequest/Reply → ConnectToPeer(F) → dial + PierceFw → ticket/offset →
    /// raw bytes → completed file with exact contents.
    func testDownloadEndToEndIndirectF() async throws {
        let server = try FakeServer()
        let uploader = try FakeServer()
        defer { server.close(); uploader.close() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let conn = ServerConnection()
        let engine = TransferEngine(server: conn, directory: dir)
        try await login(conn, server)

        let file = "@@music\\Test\\song.mp3"
        let payload = Data((0..<2048).map { UInt8($0 % 251) })
        await engine.download(username: "uploader", filename: file, size: UInt64(payload.count))

        try sendAddressReply(server, username: "uploader", port: uploader.port)

        // Uploader sees the P dial: PeerInit then QueueDownload.
        try uploader.accept()
        let pInit = try uploader.readInitFrame()
        XCTAssertEqual(pInit.code, 1)
        var ir = MessageReader(pInit.payload)
        XCTAssertEqual(try ir.string(), "tester")
        XCTAssertEqual(try ir.string(), "P")
        let queue = try uploader.readFrame()
        XCTAssertEqual(queue.code, 43)
        var qr = MessageReader(queue.payload)
        XCTAssertEqual(try qr.string(), file)

        // Uploader offers the transfer; we must accept with the right ticket.
        var treq = MessageWriter()
        treq.u32(1); treq.u32(55); treq.string(file); treq.u64(UInt64(payload.count))
        try uploader.send(treq.frame(code: 40))
        let treply = try uploader.readFrame()
        XCTAssertEqual(treply.code, 41)
        var tr = MessageReader(treply.payload)
        XCTAssertEqual(try tr.u32(), 55)
        XCTAssertEqual(try tr.u8(), 1)

        // Server brokers the indirect F connection.
        try sendConnectToF(server, username: "uploader", port: uploader.port, ticket: 99)
        try uploader.accept()
        let pierce = try uploader.readInitFrame()
        XCTAssertEqual(pierce.code, 0)
        var pr = MessageReader(pierce.payload)
        XCTAssertEqual(try pr.u32(), 99)

        // F stream: ticket u32, offset u64, raw bytes.
        try uploader.send(Data([55, 0, 0, 0]))
        var offsetBuf = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(recv(uploader.clientFd, &offsetBuf, 8, 0), 8)
        let offset = offsetBuf.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * $1.offset)) }
        XCTAssertEqual(offset, 0)
        try uploader.send(payload)

        let done = await waitForTransfer(engine) { $0.state == .completed }
        let finalTransfers = await engine.transfers
        XCTAssertTrue(done, "transfer did not complete: \(finalTransfers)")
        let firstTransfer = await engine.transfers.first
        let t = try XCTUnwrap(firstTransfer)
        XCTAssertEqual(t.received, UInt64(payload.count))
        let path = try XCTUnwrap(t.localPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), payload)

        await engine.shutdown()
        await conn.disconnect()
    }

    /// Resume: a .partial file exists; the offset sent must equal its size and
    /// only the remaining bytes are transferred.
    func testDownloadResumesFromPartial() async throws {
        let server = try FakeServer()
        let uploader = try FakeServer()
        defer { server.close(); uploader.close() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let conn = ServerConnection()
        let engine = TransferEngine(server: conn, directory: dir)
        try await login(conn, server)

        let file = "@@music\\Test\\song.mp3"
        let payload = Data((0..<2048).map { UInt8($0 % 251) })
        // Pre-existing partial: first 1024 bytes. Sanitized name = separators → "_".
        let partial = dir.appendingPathComponent("@@music_Test_song.mp3.partial")
        try payload.prefix(1024).write(to: partial)

        await engine.download(username: "uploader", filename: file, size: UInt64(payload.count))
        try sendAddressReply(server, username: "uploader", port: uploader.port)
        try uploader.accept()
        _ = try uploader.readInitFrame()
        _ = try uploader.readFrame() // QueueDownload

        var treq = MessageWriter()
        treq.u32(1); treq.u32(55); treq.string(file); treq.u64(UInt64(payload.count))
        try uploader.send(treq.frame(code: 40))
        _ = try uploader.readFrame() // TransferReply

        try sendConnectToF(server, username: "uploader", port: uploader.port, ticket: 99)
        try uploader.accept()
        _ = try uploader.readInitFrame() // PierceFw
        try uploader.send(Data([55, 0, 0, 0]))
        var offsetBuf = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(recv(uploader.clientFd, &offsetBuf, 8, 0), 8)
        let offset = offsetBuf.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * $1.offset)) }
        XCTAssertEqual(offset, 1024, "must resume from the partial size")
        try uploader.send(payload.suffix(from: 1024))

        let done = await waitForTransfer(engine) { $0.state == .completed }
        let finalTransfers = await engine.transfers
        XCTAssertTrue(done, "transfer did not complete: \(finalTransfers)")
        let firstTransfer = await engine.transfers.first
        let t = try XCTUnwrap(firstTransfer)
        let path = try XCTUnwrap(t.localPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), payload)

        await engine.shutdown()
        await conn.disconnect()
    }

    /// Queue failure surfaces as .failed with the server's reason.
    func testQueueFailureSurfacesReason() async throws {
        let server = try FakeServer()
        let uploader = try FakeServer()
        defer { server.close(); uploader.close() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let conn = ServerConnection()
        let engine = TransferEngine(server: conn, directory: dir)
        try await login(conn, server)

        let file = "@@music\\Test\\song.mp3"
        await engine.download(username: "uploader", filename: file, size: 100)
        try sendAddressReply(server, username: "uploader", port: uploader.port)
        try uploader.accept()
        _ = try uploader.readInitFrame()
        _ = try uploader.readFrame() // QueueDownload

        var fail = MessageWriter()
        fail.string(file); fail.string("File not shared")
        try uploader.send(fail.frame(code: 50))

        let failed = await waitForTransfer(engine) {
            if case .failed = $0.state { return true }
            return false
        }
        XCTAssertTrue(failed)
        let firstTransfer = await engine.transfers.first
        let t = try XCTUnwrap(firstTransfer)
        XCTAssertEqual(t.state, .failed("File not shared"))

        await engine.shutdown()
        await conn.disconnect()
    }
}