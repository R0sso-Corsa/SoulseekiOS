import Foundation
import Darwin
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

final class UploadEngineTests: XCTestCase {
    private let payload = Data((0..<4096).map { UInt8($0 % 251) })

    private func login(_ conn: ServerConnection, _ server: FakeServer) async throws {
        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame()
        try server.send(loginSuccessFrame(greeting: "", ip: [127, 0, 0, 1], privileged: false))
        for _ in 0..<9 { _ = try server.readFrame() }
        await connecting
    }

    /// Temp share root with one deterministic file; returns (index, virtualPath).
    private func makeShare() async throws -> (ShareIndex, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareRoot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: root.appendingPathComponent("test.mp3"))
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let index = ShareIndex(storeURL: store)
        await index.addRoot(root.path)
        return (index, root.lastPathComponent + "\\test.mp3", root)
    }

    private func sendConnectToP(_ server: FakeServer, username: String, port: UInt16, ticket: UInt32) throws {
        var w = MessageWriter()
        w.string(username); w.string("P")
        w.u8(1); w.u8(0); w.u8(0); w.u8(127)
        w.u32(UInt32(port)); w.u32(ticket); w.u8(0)
        w.u32(0); w.u32(0)
        try server.send(w.frame(code: 18))
    }

    private func sendAddressReply(_ server: FakeServer, username: String, port: UInt16) throws {
        let req = try server.readFrame()
        XCTAssertEqual(req.code, 3)
        var w = MessageWriter()
        w.string(username)
        w.u8(1); w.u8(0); w.u8(0); w.u8(127)
        w.u32(UInt32(port))
        w.u32(0); w.u8(0); w.u8(0)
        try server.send(w.frame(code: 3))
    }

    private func waitForUpload(_ engine: UploadEngine, timeout: TimeInterval = 10, where match: @escaping (UploadEngine.Upload) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await engine.uploads.contains(where: match) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// Full DIRECT upload: ConnectToPeer(P) → we dial → QueueDownload →
    /// TransferRequest(dir 0) → Reply → GetPeerAddress → direct F → ticket →
    /// offset → exact bytes → completed.
    func testUploadDirectF() async throws {
        let server = try FakeServer()
        let downloader = try FakeServer()
        defer { server.close(); downloader.close() }
        let (index, virtualPath, root) = try await makeShare()
        defer { try? FileManager.default.removeItem(at: root) }

        let conn = ServerConnection()
        let uploads = UploadEngine(server: conn, index: index)
        let search = SearchEngine(server: conn,
            onUploadRequest: { link, user, file, pending in
                await uploads.handleQueueDownload(link, username: user, filename: file, pending: pending)
            },
            onUploadConnection: { link, ticket, pending in
                await uploads.handleIndirectUpload(link, ticket: ticket, pending: pending)
            })
        try await login(conn, server)
        addTeardownBlock { await uploads.shutdown(); await search.shutdown(); await conn.disconnect() }

        // Downloader asks via the indirect P path.
        try sendConnectToP(server, username: "downloader", port: downloader.port, ticket: 55)
        try downloader.accept()
        let pierce = try downloader.readInitFrame()
        XCTAssertEqual(pierce.code, 0)
        var pr = MessageReader(pierce.payload)
        XCTAssertEqual(try pr.u32(), 55)
        try downloader.send(PeerMessages.queueDownload(filename: virtualPath))

        // We send TransferRequest(direction 0) with the right size.
        let treq = try downloader.readFrame()
        XCTAssertEqual(treq.code, 40)
        var tr = MessageReader(treq.payload)
        XCTAssertEqual(try tr.u32(), 0) // direction = upload
        let ticket = try tr.u32()
        XCTAssertEqual(try tr.string(), virtualPath)
        XCTAssertEqual(try tr.u64(), UInt64(payload.count))
        try downloader.send(PeerMessages.transferReply(ticket: ticket, allowed: true, filesize: UInt64(payload.count)))

        // We resolve the downloader's address and dial F directly.
        try sendAddressReply(server, username: "downloader", port: downloader.port)
        try downloader.accept()
        var ticketBuf = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(recv(downloader.clientFd, &ticketBuf, 4, 0), 4)
        var off = MessageWriter()
        off.u64(0)
        try downloader.send(Data(off.bytes))

        // Exact bytes arrive.
        var received = Data()
        while received.count < payload.count {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(downloader.clientFd, &buf, buf.count, 0)
            guard n > 0 else { break }
            received.append(Data(buf[0..<n]))
        }
        XCTAssertEqual(received, payload)
        let done = await waitForUpload(uploads) { $0.state == .completed && $0.sent == UInt64(self.payload.count) }
        let states = await uploads.uploads.map { "\($0.state)" }
        XCTAssertTrue(done, "upload not completed: \(states)")
    }

    /// Full INDIRECT upload (both behind NAT): address reply port 0 → we send
    /// ConnectToPeer(F) → downloader dials OUR listener with PierceFw →
    /// ticket → offset → exact bytes.
    func testUploadIndirectF() async throws {
        let server = try FakeServer()
        let downloader = try FakeServer()
        defer { server.close(); downloader.close() }
        let (index, virtualPath, root) = try await makeShare()
        defer { try? FileManager.default.removeItem(at: root) }

        let conn = ServerConnection()
        let uploads = UploadEngine(server: conn, index: index)
        let search = SearchEngine(server: conn,
            onUploadRequest: { link, user, file, pending in
                await uploads.handleQueueDownload(link, username: user, filename: file, pending: pending)
            },
            onUploadConnection: { link, ticket, pending in
                await uploads.handleIndirectUpload(link, ticket: ticket, pending: pending)
            })
        try await login(conn, server)
        await search.startListening()
        addTeardownBlock { await uploads.shutdown(); await search.shutdown(); await conn.disconnect() }
        // Listener port is published asynchronously by NWListener.
        var listenPort: UInt16 = 0
        let portDeadline = Date().addingTimeInterval(5)
        while Date() < portDeadline {
            listenPort = await search.state.listenPort
            if listenPort > 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(listenPort, 0)
        // startListening re-advertises SetListenPort(2) — drain it.
        let portFrame = try server.readFrame()
        XCTAssertEqual(portFrame.code, 2)

        try sendConnectToP(server, username: "downloader", port: downloader.port, ticket: 55)
        try downloader.accept()
        _ = try downloader.readInitFrame()
        try downloader.send(PeerMessages.queueDownload(filename: virtualPath))
        let treq = try downloader.readFrame()
        XCTAssertEqual(treq.code, 40)
        var tr = MessageReader(treq.payload)
        _ = try tr.u32()
        let ticket = try tr.u32()
        try downloader.send(PeerMessages.transferReply(ticket: ticket, allowed: true, filesize: UInt64(payload.count)))

        // Downloader is firewalled: port 0 → we must send ConnectToPeer(F).
        try sendAddressReply(server, username: "downloader", port: 0)
        let ctp = try server.readFrame()
        XCTAssertEqual(ctp.code, 18)
        var cr = MessageReader(ctp.payload)
        XCTAssertEqual(try cr.u32(), ticket)
        XCTAssertEqual(try cr.string(), "downloader")
        XCTAssertEqual(try cr.string(), "F")

        // Downloader dials our listener and pierces with the ticket.
        let fd = try dialListener(port: listenPort)
        defer { Darwin.close(fd) }
        try sendAll(fd, PeerInitMessages.pierceFirewall(ticket: ticket))
        var ticketBuf = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(recv(fd, &ticketBuf, 4, 0), 4)
        XCTAssertEqual(Data(ticketBuf), Data([UInt8(ticket & 0xFF), UInt8((ticket >> 8) & 0xFF), UInt8((ticket >> 16) & 0xFF), UInt8(ticket >> 24)]))
        var off = MessageWriter()
        off.u64(0)
        try sendAll(fd, Data(off.bytes))

        var received = Data()
        while received.count < payload.count {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { break }
            received.append(Data(buf[0..<n]))
        }
        XCTAssertEqual(received, payload)
        let done = await waitForUpload(uploads) { $0.state == .completed }
        let states = await uploads.uploads.map { "\($0.state)" }
        XCTAssertTrue(done, "indirect upload not completed: \(states)")
    }

    /// Unshared file → QueueFailed(50) with a reason.
    func testQueueFailedForUnshared() async throws {
        let server = try FakeServer()
        let downloader = try FakeServer()
        defer { server.close(); downloader.close() }
        let (index, _, root) = try await makeShare()
        defer { try? FileManager.default.removeItem(at: root) }

        let conn = ServerConnection()
        let uploads = UploadEngine(server: conn, index: index)
        let search = SearchEngine(server: conn,
            onUploadRequest: { link, user, file, pending in
                await uploads.handleQueueDownload(link, username: user, filename: file, pending: pending)
            })
        try await login(conn, server)
        addTeardownBlock { await uploads.shutdown(); await search.shutdown(); await conn.disconnect() }

        try sendConnectToP(server, username: "downloader", port: downloader.port, ticket: 55)
        try downloader.accept()
        _ = try downloader.readInitFrame()
        try downloader.send(PeerMessages.queueDownload(filename: "not\\shared.mp3"))
        let denied = try downloader.readFrame()
        XCTAssertEqual(denied.code, 50)
        var dr = MessageReader(denied.payload)
        XCTAssertEqual(try dr.string(), "not\\shared.mp3")
        XCTAssertEqual(try dr.string(), "File not shared.")
    }

    // MARK: - Raw socket helpers

    private func dialListener(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FakeServer.Failure.socket("socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { Darwin.close(fd); throw FakeServer.Failure.socket("connect") }
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func sendAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { ptr in
                Darwin.send(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard n > 0 else { throw FakeServer.Failure.socket("send") }
            sent += n
        }
    }
}