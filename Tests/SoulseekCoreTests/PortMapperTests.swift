import Foundation
import Network
import XCTest
@testable import SoulseekCore

/// NAT-PMP (RFC 6886) packet codec + loopback mapping exchange.
final class PortMapperTests: XCTestCase {
    func testAddressRequestGolden() {
        XCTAssertEqual(PortMapper.addressRequest(), Data([0x00, 0x00]))
    }

    func testMapRequestGolden() {
        // version 0, opcode 2, reserved u16, internal 2234, external 2234,
        // lifetime 7200 — all big-endian.
        let expected = Data([0x00, 0x02, 0x00, 0x00, 0x08, 0xBA, 0x08, 0xBA, 0x00, 0x00, 0x1C, 0x20])
        XCTAssertEqual(PortMapper.mapRequest(internalPort: 2234, externalPort: 2234, lifetime: 7200), expected)
    }

    func testAddressResponseParse() throws {
        let data = Data([0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, 0xCB, 0x00, 0x71, 0x07])
        let ip = try XCTUnwrap(PortMapper.parseAddressResponse(data))
        XCTAssertEqual(ip, "203.0.113.7")
    }

    func testMapResponseParse() throws {
        let data = Data([0x00, 0x82, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8,
                         0x08, 0xBA, 0x09, 0xC4, 0x00, 0x00, 0x1C, 0x20])
        let mapping = try XCTUnwrap(PortMapper.parseMapResponse(data))
        XCTAssertEqual(mapping.externalPort, 2500)
        XCTAssertEqual(mapping.lifetime, 7200)
    }

    func testErrorResultRejected() {
        // result code 2 (not authorized) must not parse as a mapping.
        let data = Data([0x00, 0x82, 0x00, 0x02, 0x00, 0x00, 0x03, 0xE8,
                         0x08, 0xBA, 0x09, 0xC4, 0x00, 0x00, 0x1C, 0x20])
        XCTAssertNil(PortMapper.parseMapResponse(data))
    }

    /// Loopback exchange against a fake NAT-PMP gateway (UDP).
    func testMapTCPLoopback() async throws {
        let gateway = try FakeNATPMP()
        defer { gateway.close() }
        let mapper = PortMapper(gateway: "127.0.0.1", port: gateway.port)
        let mapping = await mapper.mapTCP(internalPort: 2234)
        let m = try XCTUnwrap(mapping, "loopback mapping failed")
        XCTAssertEqual(m.externalIP, "127.0.0.1")
        XCTAssertEqual(m.externalPort, 2234)
        XCTAssertEqual(m.lifetime, 7200)
    }
}

/// Minimal UDP NAT-PMP responder: external address = 127.0.0.1, maps any
/// requested port to itself with the requested lifetime.
final class FakeNATPMP {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private var conns: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .udp, on: .any)
        var ready = false
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready = true }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.conns.append(conn)
            conn.start(queue: DispatchQueue(label: "fake.natpmp"))
            self?.receive(on: conn)
        }
        listener.start(queue: DispatchQueue(label: "fake.natpmp.listener"))
        let deadline = Date().addingTimeInterval(5)
        while !ready && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard let p = listener.port else { throw NSError(domain: "FakeNATPMP", code: 1) }
        port = p.rawValue
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            let response = self.respond(to: data)
            conn.send(content: response, completion: .contentProcessed { _ in })
            self.receive(on: conn)
        }
    }

    private func respond(to request: Data) -> Data {
        guard request.count >= 2, request[0] == 0 else { return Data() }
        var out = Data([0x00, 0x80 | request[1], 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8])
        if request[1] == 0 {
            out.append(contentsOf: [127, 0, 0, 1])
        } else if request[1] == 2, request.count >= 12 {
            out.append(request[4..<6])  // internal port echo
            out.append(request[6..<8])  // external port = requested
            out.append(request[8..<12]) // lifetime echo
        }
        return out
    }

    func close() {
        listener.cancel()
        for c in conns { c.cancel() }
    }
}