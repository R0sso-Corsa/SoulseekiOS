import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// NAT-PMP (RFC 6886) port mapping so peers can dial us directly on Wi-Fi
/// networks whose gateway supports it. Degrades silently when unavailable —
/// the indirect (server-brokered) path keeps working either way.
public struct PortMapping: Equatable, Sendable {
    public let externalIP: String
    public let externalPort: UInt16
    public let lifetime: UInt32
}

public actor PortMapper {
    struct MapResult {
        let externalPort: UInt16
        let lifetime: UInt32
    }

    private let gatewayOverride: String?
    private let port: UInt16

    public init(gateway: String? = nil, port: UInt16 = 5351) {
        self.gatewayOverride = gateway
        self.port = port
    }

    /// Map a TCP port; returns the external endpoint + lease, or nil when the
    /// gateway is undiscoverable / refuses NAT-PMP.
    public func mapTCP(internalPort: UInt16, lifetime: UInt32 = 7200) async -> PortMapping? {
        guard let gw = gatewayOverride ?? Self.defaultGateway() ?? Self.subnetGateway() else { return nil }
        guard let addrResp = await exchange(Self.addressRequest(), gateway: gw),
              let extIP = Self.parseAddressResponse(addrResp) else { return nil }
        let req = Self.mapRequest(internalPort: internalPort, externalPort: internalPort, lifetime: lifetime)
        guard let resp = await exchange(req, gateway: gw),
              let result = Self.parseMapResponse(resp) else { return nil }
        return PortMapping(externalIP: extIP, externalPort: result.externalPort, lifetime: result.lifetime)
    }

    // MARK: - Codec (big-endian, unlike Soulseek framing)

    static func addressRequest() -> Data { Data([0x00, 0x00]) }

    static func mapRequest(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> Data {
        var d = Data([0x00, 0x02, 0x00, 0x00])
        d.append(UInt8(internalPort >> 8)); d.append(UInt8(internalPort & 0xFF))
        d.append(UInt8(externalPort >> 8)); d.append(UInt8(externalPort & 0xFF))
        for shift in stride(from: 24, through: 0, by: -8) {
            d.append(UInt8((lifetime >> UInt32(shift)) & 0xFF))
        }
        return d
    }

    static func parseAddressResponse(_ d: Data) -> String? {
        guard d.count >= 12, d[0] == 0, d[1] == 0x80, d[2] == 0, d[3] == 0 else { return nil }
        return "\(d[8]).\(d[9]).\(d[10]).\(d[11])"
    }

    static func parseMapResponse(_ d: Data) -> MapResult? {
        guard d.count >= 16, d[0] == 0, d[1] == 0x82, d[2] == 0, d[3] == 0 else { return nil }
        let ext = UInt16(d[10]) << 8 | UInt16(d[11])
        let life = UInt32(d[12]) << 24 | UInt32(d[13]) << 16 | UInt32(d[14]) << 8 | UInt32(d[15])
        return MapResult(externalPort: ext, lifetime: life)
    }

    // MARK: - UDP exchange (2 tries, 3s each per RFC guidance)

    private func exchange(_ request: Data, gateway: String) async -> Data? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let conn = NWConnection(host: NWEndpoint.Host(gateway), port: endpointPort, using: .udp)
        guard await nwWaitReady(conn) else { conn.cancel(); return nil }
        defer { conn.cancel() }
        for _ in 0..<2 {
            try? await nwSend(conn, data: request)
            if let resp = await nwReceiveChunk(conn, timeout: 3_000_000_000), resp.count >= 2 {
                return resp
            }
        }
        return nil
    }

    // MARK: - Gateway discovery

    /// Default route via the routing sysctl (works on iOS, no entitlement).
    /// rt_msghdr isn't in Swift's iOS Darwin overlay, so read the arm64 ABI
    /// layout directly: msglen u16 @0, flags i32 @8, sockaddrs @92.
    static func defaultGateway() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, 0x2 /* RTF_GATEWAY */]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buffer, &needed, nil, 0) == 0 else { return nil }
        let hdrSize = 92
        var offset = 0
        while offset + hdrSize <= needed {
            let msgLen = Int(UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8))
            if msgLen <= 0 || offset + msgLen > needed { break }
            let flags = UInt32(buffer[offset + 8]) | (UInt32(buffer[offset + 9]) << 8)
                | (UInt32(buffer[offset + 10]) << 16) | (UInt32(buffer[offset + 11]) << 24)
            if flags & 0x2 != 0 { // RTF_GATEWAY
                var saOffset = offset + hdrSize
                var addrs: [sockaddr_in] = []
                for _ in 0..<2 {
                    guard saOffset + MemoryLayout<sockaddr>.size <= offset + msgLen else { break }
                    let sa = buffer.withUnsafeBytes { $0.load(fromByteOffset: saOffset, as: sockaddr.self) }
                    let saLen = Int(sa.sa_len)
                    if sa.sa_family == sa_family_t(AF_INET), saLen >= MemoryLayout<sockaddr_in>.size {
                        addrs.append(buffer.withUnsafeBytes { $0.load(fromByteOffset: saOffset, as: sockaddr_in.self) })
                    }
                    saOffset += max(4, (saLen + 3) & ~3)
                }
                // Default route: destination 0.0.0.0, gateway is the second address.
                if addrs.count >= 2, addrs[0].sin_addr.s_addr == 0 {
                    let g = addrs[1].sin_addr.s_addr
                    let b = withUnsafeBytes(of: g) { Array($0) }
                    return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
                }
            }
            offset += msgLen
        }
        return nil
    }

    /// Fallback: the .1 address of the primary IPv4 interface's subnet.
    static func subnetGateway() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let b = withUnsafeBytes(of: sin.sin_addr.s_addr) { Array($0) }
            if b[0] == 127 { continue }
            return "\(b[0]).\(b[1]).\(b[2]).1"
        }
        return nil
    }
}