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
}

private extension Data {
    init(hexString: String) {
        self.init(stride(from: 0, to: hexString.count, by: 2).map {
            UInt8(hexString.dropFirst($0).prefix(2), radix: 16)!
        })
    }
}