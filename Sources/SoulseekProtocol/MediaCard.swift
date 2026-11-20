import Foundation

/// Chat media attachment convention (AD-16): a text line carrying the
/// metadata of a file the sender temporarily shares. App users' clients
/// auto-fetch the bytes over the normal Soulseek transfer path and render
/// the picture/video inline; other clients show the plain text line.
/// The server never sees binary — only this short JSON line.
public struct MediaCard: Equatable, Sendable {
    public static let prefix = "slsk-media:"

    public enum Kind: String, Sendable {
        case image, video
    }

    public let username: String
    public let path: String
    public let size: UInt64
    public let kind: Kind
    public let ext: String

    public init(username: String, path: String, size: UInt64, kind: Kind, ext: String) {
        self.username = username
        self.path = path
        self.size = size
        self.kind = kind
        self.ext = ext
    }

    public var title: String {
        if let i = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            return String(path[path.index(after: i)...])
        }
        return path
    }

    public func encoded() -> String {
        let obj: [String: Any] = ["u": username, "p": path, "s": size, "t": kind.rawValue, "e": ext]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else {
            return Self.prefix + "{}"
        }
        return Self.prefix + json
    }

    public static func parse(_ text: String) -> MediaCard? {
        guard text.hasPrefix(prefix) else { return nil }
        let json = String(text.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let u = obj["u"] as? String, !u.isEmpty,
              let p = obj["p"] as? String, !p.isEmpty,
              let t = obj["t"] as? String, let kind = Kind(rawValue: t) else { return nil }
        let s: UInt64
        if let n = obj["s"] as? UInt64 { s = n }
        else if let n = obj["s"] as? Int, n >= 0 { s = UInt64(n) }
        else if let n = obj["s"] as? Double, n >= 0 { s = UInt64(n) }
        else { return nil }
        let e = (obj["e"] as? String) ?? ""
        return MediaCard(username: u, path: p, size: s, kind: kind, ext: e)
    }
}