import Foundation
import Darwin

import XCTest
import SoulseekProtocol
@testable import SoulseekCore

final class BrowseEngineTests: XCTestCase {
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
        var w = MessageWriter()
        w.string(username)
        w.u8(1); w.u8(0); w.u8(0); w.u8(127)
        w.u32(UInt32(port))
        w.u32(0); w.u8(0); w.u8(0)
        try server.send(w.frame(code: 3))
    }

    /// Direct P browse: GetPeerAddress → dial → PeerInit(P) → code 4 →
    /// zlib SharedFileList(5) → decoded folders.
    func testBrowseEndToEnd() async throws {
        let server = try FakeServer()
        let sharer = try FakeServer()
        defer { server.close(); sharer.close() }
        let conn = ServerConnection()
        let engine = BrowseEngine(server: conn)
        addTeardownBlock { await conn.disconnect() }
        try await login(conn, server)

        async let browsing = engine.browse(username: "sharer")
        try sendAddressReply(server, username: "sharer", port: sharer.port)

        try sharer.accept()
        let pInit = try sharer.readInitFrame()
        XCTAssertEqual(pInit.code, 1)
        var ir = MessageReader(pInit.payload)
        XCTAssertEqual(try ir.string(), "tester")
        XCTAssertEqual(try ir.string(), "P")
        let req = try sharer.readFrame()
        XCTAssertEqual(req.code, 4)
        XCTAssertTrue(req.payload.isEmpty)

        // Same zlib fixture as the codec golden.
        let frame = Data(hexString: "4300000005000000789c63646060e00662dfd2e2cce418c79ca4d25c4620979113489414252667ebe516183b3c0289313030033190cbc400010e405190c40906040000267b0afb")
        try sharer.send(frame)

        let folders = try await browsing
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].path, "Music\\Album")
        XCTAssertEqual(folders[0].files[0].path, "track.mp3")
        XCTAssertEqual(folders[0].files[0].size, 123456)
        await conn.disconnect()
    }

    /// Firewalled sharer: direct dial refused → ConnectToPeer(P) → sharer
    /// dials our listener with PierceFw → GetShareFileList → SharedFileList.
    func testBrowseIndirectP() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let engine = BrowseEngine(server: conn)
        let search = SearchEngine(server: conn, onPierce: { link, ticket, _ in
            await engine.handleIndirectBrowse(link, ticket: ticket)
        })
        addTeardownBlock { await search.shutdown(); await conn.disconnect() }
        try await login(conn, server)
        await search.startListening()
        var listenPort: UInt16 = 0
        let portDeadline = Date().addingTimeInterval(5)
        while Date() < portDeadline {
            listenPort = await search.state.listenPort
            if listenPort > 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(listenPort, 0)
        let portFrame = try server.readFrame()
        XCTAssertEqual(portFrame.code, 2)

        async let browsing = engine.browse(username: "sharer")
        // Online but unreachable → indirect P request.
        try sendAddressReply(server, username: "sharer", port: 1)
        let ctp = try server.readFrame()
        XCTAssertEqual(ctp.code, 18)
        var cr = MessageReader(ctp.payload)
        let ticket = try cr.u32()
        XCTAssertEqual(try cr.string(), "sharer")
        XCTAssertEqual(try cr.string(), "P")

        // Sharer dials our listener and pierces; we send GetShareFileList.
        let fd = try dialListener(port: listenPort)
        defer { Darwin.close(fd) }
        try sendAll(fd, PeerInitMessages.pierceFirewall(ticket: ticket))
        var reader = FrameReader()
        var reqFrame: Frame?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && reqFrame == nil {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { break }
            reader.append(Data(buf[0..<n]))
            reqFrame = try reader.next()
        }
        let req = try XCTUnwrap(reqFrame)
        XCTAssertEqual(req.code, 4)

        try sendAll(fd, Data(hexString: "4300000005000000789c63646060e00662dfd2e2cce418c79ca4d25c4620979113489414252667ebe516183b3c0289313030033190cbc400010e405190c40906040000267b0afb"))
        let folders = try await browsing
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].path, "Music\\Album")
    }

    func testBrowseOfflineUser() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let engine = BrowseEngine(server: conn)
        addTeardownBlock { await conn.disconnect() }
        try await login(conn, server)

        async let browsing = engine.browse(username: "ghost")
        // Port 0 = offline/firewalled per protocol.
        try sendAddressReply(server, username: "ghost", port: 0)
        do {
            _ = try await browsing
            XCTFail("expected offline error")
        } catch let error as BrowseEngine.BrowseError {
            XCTAssertEqual(error, .offline)
        }
        await conn.disconnect()
    }

    func testUserStatsAndStatus() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        try await login(conn, server)

        async let stats = conn.userStats(for: "alice")
        let statsReq = try server.readFrame()
        XCTAssertEqual(statsReq.code, 36)
        var sw = MessageWriter()
        sw.string("alice"); sw.u32(50000); sw.u32(1234); sw.u32(0); sw.u32(300); sw.u32(20)
        try server.send(sw.frame(code: 36))
        let s = try await stats
        XCTAssertEqual(s.username, "alice")
        XCTAssertEqual(s.avgSpeed, 50000)
        XCTAssertEqual(s.files, 300)
        XCTAssertEqual(s.folders, 20)

        async let status = conn.userStatus(for: "alice")
        let statusReq = try server.readFrame()
        XCTAssertEqual(statusReq.code, 7)
        var w = MessageWriter()
        w.string("alice"); w.u32(2); w.u8(1)
        try server.send(w.frame(code: 7))
        let st = try await status
        XCTAssertEqual(st.status, .online)
        XCTAssertTrue(st.privileged)
        await conn.disconnect()
    }

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

private extension Data {
    init(hexString: String) {
        self.init(stride(from: 0, to: hexString.count, by: 2).map {
            UInt8(hexString.dropFirst($0).prefix(2), radix: 16)!
        })
    }
}