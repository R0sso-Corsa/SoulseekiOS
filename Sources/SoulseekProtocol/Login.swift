import Foundation
import CryptoKit

/// Login (server code 1). Field order per aioslsk MESSAGES docs:
/// username, password, client_version, md5hash(username+password), minor_version.
public enum Login {
    /// aioslsk's reserved modern version; the server restricts ancient clients.
    public static let clientVersion: UInt32 = 175
    public static let minorVersion: UInt32 = 1

    public static func frame(username: String, password: String) -> Data {
        var w = MessageWriter()
        w.string(username)
        w.string(password)
        w.u32(clientVersion)
        w.string(md5Hex(username + password))
        w.u32(minorVersion)
        return w.frame(code: 1)
    }
}

/// Login response: success, then greeting/ip/passwordMD5/privileged on success
/// or a failure reason string.
public struct LoginResponse {
    public let success: Bool
    public let greeting: String?
    public let ip: String?
    public let passwordMD5: String?
    public let privileged: Bool?
    public let reason: String?

    public init(payload: Data) throws {
        var r = MessageReader(payload)
        success = try r.u8() != 0
        if success {
            greeting = try r.string()
            ip = try r.ipaddr()
            passwordMD5 = try r.string()
            privileged = try r.u8() != 0
            reason = nil
        } else {
            greeting = nil
            ip = nil
            passwordMD5 = nil
            privileged = nil
            reason = try r.string()
        }
    }
}

public func md5Hex(_ text: String) -> String {
    Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}