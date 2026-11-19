import Foundation
import XCTest
@testable import SoulseekCore

/// Opt-in live probe: does this network's gateway honor NAT-PMP?
/// Prints the mapping when available; skips (not fails) when the gateway
/// refuses — the indirect transfer path covers that case.
final class LivePortMapTests: XCTestCase {
    func testLiveNATPMPMapping() async throws {
        guard ProcessInfo.processInfo.environment["SLSK_USER"] != nil else {
            throw XCTSkip("live tests opt-in")
        }
        let gw = PortMapper.defaultGateway() ?? PortMapper.subnetGateway()
        print("LIVE NATPMP: gateway=\(gw ?? "undiscoverable")")
        guard gw != nil else { throw XCTSkip("no gateway discovered") }
        let mapper = PortMapper()
        // Map a high test port (not the app listener) to avoid side effects.
        guard let mapping = await mapper.mapTCP(internalPort: 22234, lifetime: 300) else {
            throw XCTSkip("gateway refused NAT-PMP — indirect path remains the fallback")
        }
        print("LIVE NATPMP OK: external \(mapping.externalIP):\(mapping.externalPort) lifetime=\(mapping.lifetime)")
        XCTAssertGreaterThan(mapping.externalPort, 0)
    }
}