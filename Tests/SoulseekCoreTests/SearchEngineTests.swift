import Foundation
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Frames arbitrary payload with a u32 code (test helper).
func frameBytes(code: UInt32, payload: Data) -> Data {
    var w = MessageWriter()
    w.u32(UInt32(payload.count + 4))
    w.u32(code)
    return Data(w.bytes) + payload
}

extension FakeServer {
    /// First frame on a peer connection uses a u8 code (PeerInit / PierceFw).
    func readInitFrame() throws -> (code: UInt8, payload: Data) {
        var buf = Data()
        while true {
            if let parsed = try PeerInitMessages.parseInitFrame(buf) {
                return (parsed.code, parsed.payload)
            }
            var tmp = [UInt8](repeating: 0, count: 65536)
            let n = recv(clientFd, &tmp, tmp.count, 0)
            guard n > 0 else { throw Failure.timeout("readInitFrame") }
            buf.append(Data(tmp[0..<n]))
        }
    }
}

final class SearchEngineTests: XCTestCase {
    private func waitForState(_ engine: SearchEngine, timeout: TimeInterval = 6, where match: @escaping (SearchEngine.State) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await match(engine.state) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// The whole indirect search path on loopback:
    /// login → handshake → listener port advertised → FileSearch(26) →
    /// ConnectToPeer(18) → outbound dial → PierceFw(0) → PeerSearchReply(9, zlib)
    /// → decoded result in engine state → timeout finishes the search.
    func testIndirectSearchFlowEndToEnd() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let responder = try FakeServer()
        defer { responder.close() }

        let conn = ServerConnection()
        let engine = SearchEngine(server: conn)

        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame() // login
        try server.send(loginSuccessFrame(greeting: "", ip: [127, 0, 0, 1], privileged: false))
        for _ in 0..<9 { _ = try server.readFrame() } // handshake
        await connecting

        // Listener up → server gets a SetListenPort update with a real port.
        await engine.startListening()
        let portUpdate = try server.readFrame()
        XCTAssertEqual(portUpdate.code, 2)
        var pr = MessageReader(portUpdate.payload)
        let advertisedPort = try pr.u32()
        XCTAssertGreaterThan(advertisedPort, 0)

        // Search → server gets FileSearch(26) with our ticket + query.
        await engine.search("flac", timeout: 3)
        let searchFrame = try server.readFrame()
        XCTAssertEqual(searchFrame.code, 26)
        var sr = MessageReader(searchFrame.payload)
        let ticket = try sr.u32()
        XCTAssertEqual(try sr.string(), "flac")

        // Server tells us to dial the responder indirectly.
        var ctp = MessageWriter()
        ctp.string("responder")
        ctp.string("P")
        ctp.u8(1); ctp.u8(0); ctp.u8(0); ctp.u8(127) // 127.0.0.1, least-significant first
        ctp.u32(UInt32(responder.port))
        ctp.u32(ticket)
        ctp.u8(0)
        ctp.u32(0); ctp.u32(0)
        try server.send(ctp.frame(code: 18))

        // Responder sees our outbound dial and the PierceFw with the ticket.
        try responder.accept()
        let pierce = try responder.readInitFrame()
        XCTAssertEqual(pierce.code, 0)
        var pierceReader = MessageReader(pierce.payload)
        XCTAssertEqual(try pierceReader.u32(), ticket)

        // Responder sends a zlib-compressed PeerSearchReply.
        var body = MessageWriter()
        body.string("responder")
        body.u32(ticket)
        body.u32(1) // one file
        body.u8(1)
        body.string("@@music\\Test\\song.mp3")
        body.u64(999)
        body.string("mp3")
        body.u32(2)
        body.u32(0); body.u32(320)  // bitrate
        body.u32(1); body.u32(180)  // duration
        body.u8(1)                  // slots free
        body.u32(50000)             // avg speed
        body.u32(0)                 // queue
        body.u32(0)                 // unknown
        body.u32(0)                 // locked count
        let compressed = try Zlib.deflate(Data(body.bytes))
        try responder.send(frameBytes(code: 9, payload: compressed))

        let gotResult = await waitForState(engine) { !$0.replies.isEmpty }
        XCTAssertTrue(gotResult, "no search reply arrived")
        let state = await engine.state
        XCTAssertEqual(state.replies.count, 1)
        XCTAssertEqual(state.replies[0].username, "responder")
        XCTAssertEqual(state.replies[0].ticket, ticket)
        XCTAssertEqual(state.replies[0].files.count, 1)
        XCTAssertEqual(state.replies[0].files[0].filename, "song.mp3")
        XCTAssertEqual(state.replies[0].files[0].bitrate, 320)
        XCTAssertEqual(state.replies[0].files[0].duration, 180)
        XCTAssertEqual(state.replies[0].freeSlots, true)
        XCTAssertTrue(state.isSearching)

        // Timeout finishes the search.
        let finished = await waitForState(engine, timeout: 6) { $0.finished }
        XCTAssertTrue(finished)
        let finalState = await engine.state
        XCTAssertFalse(finalState.isSearching)
        XCTAssertEqual(finalState.replies.count, 1, "results survive completion")

        await engine.shutdown()
        await conn.disconnect()
    }

    func testSearchTimesOutWithNoResults() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()
        let engine = SearchEngine(server: conn)

        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame()
        try server.send(loginSuccessFrame(greeting: "", ip: [127, 0, 0, 1], privileged: false))
        for _ in 0..<9 { _ = try server.readFrame() }
        await connecting

        await engine.search("nothing_matches_this", timeout: 1)
        let searchFrame = try server.readFrame()
        XCTAssertEqual(searchFrame.code, 26)

        let finished = await waitForState(engine, timeout: 5) { $0.finished }
        XCTAssertTrue(finished)
        let state = await engine.state
        XCTAssertTrue(state.replies.isEmpty)
        XCTAssertFalse(state.isSearching)

        await engine.shutdown()
        await conn.disconnect()
    }
}