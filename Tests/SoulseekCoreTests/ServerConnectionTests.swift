import Foundation
import Darwin
import XCTest
import SoulseekProtocol
@testable import SoulseekCore

/// Scripted Soulseek server on loopback — deterministic, no external network.
final class FakeServer {
    enum Failure: Error { case socket(String), timeout(String) }

    private let listener: Int32
    private var client: Int32 = -1
    private var reader = FrameReader()
    let port: UInt16

    /// Exposed for test extensions that read peer-init (u8 code) frames.
    var clientFd: Int32 { client }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { throw Failure.socket("bind/listen") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actual = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        listener = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    func accept(timeout: TimeInterval = 5) throws {
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { throw Failure.timeout("accept") }
        client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { throw Failure.socket("accept") }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func readFrame() throws -> Frame {
        while true {
            if let frame = try reader.next() { return frame }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(client, &buf, buf.count, 0)
            guard n > 0 else { throw Failure.timeout("readFrame") }
            reader.append(Data(buf[0..<n]))
        }
    }

    func send(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { ptr in
                Darwin.send(client, ptr.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard n > 0 else { throw Failure.socket("send") }
            sent += n
        }
    }

    func close() {
        if client >= 0 { Darwin.close(client); client = -1 }
        Darwin.close(listener)
    }
}

func loginSuccessFrame(greeting: String, ip: [UInt8], privileged: Bool) -> Data {
    var w = MessageWriter()
    w.u8(1)
    w.string(greeting)
    for byte in ip { w.u8(byte) }
    w.string("passwordmd5")
    w.u8(privileged ? 1 : 0)
    return w.frame(code: 1)
}

func loginFailureFrame(reason: String) -> Data {
    var w = MessageWriter()
    w.u8(0)
    w.string(reason)
    return w.frame(code: 1)
}

final class ServerConnectionTests: XCTestCase {
    private func waitForState(_ conn: ServerConnection, timeout: TimeInterval = 5, where match: @escaping (ServerConnection.State) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await match(conn.state) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testConnectSendsLoginThenHandshakeAndReachesConnected() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()

        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()

        let login = try server.readFrame()
        XCTAssertEqual(login.code, 1)
        var r = MessageReader(login.payload)
        XCTAssertEqual(try r.string(), "tester")
        XCTAssertEqual(try r.string(), "pw")

        try server.send(loginSuccessFrame(greeting: "hello", ip: [1, 2, 3, 4], privileged: false))

        var codes: [UInt32] = []
        for _ in 0..<9 { codes.append(try server.readFrame().code) }
        XCTAssertEqual(codes, [92, 2, 28, 35, 5, 71, 127, 126, 100])

        await connecting
        let state = await conn.state
        XCTAssertEqual(state, .connected(greeting: "hello", publicIP: "4.3.2.1", privileged: false))

        await conn.disconnect()
        let after = await conn.state
        XCTAssertEqual(after, .disconnected)
    }

    func testLoginFailureSurfacesReason() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()

        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame() // login
        try server.send(loginFailureFrame(reason: "INVALIDPASS"))

        await connecting
        let state = await conn.state
        XCTAssertEqual(state, .failed("INVALIDPASS"))
    }

    func testKickedMessageDisconnects() async throws {
        let server = try FakeServer()
        defer { server.close() }
        let conn = ServerConnection()

        async let connecting: Void = conn.connect(username: "tester", password: "pw", host: "127.0.0.1", port: server.port)
        try server.accept()
        _ = try server.readFrame()
        try server.send(loginSuccessFrame(greeting: "", ip: [127, 0, 0, 1], privileged: false))
        for _ in 0..<9 { _ = try server.readFrame() }
        await connecting

        try server.send(MessageWriter().frame(code: 41)) // Kicked
        let kicked = await waitForState(conn) { $0 == .kicked }
        let finalState = await conn.state
        XCTAssertTrue(kicked, "expected .kicked, got \(finalState)")
    }
}