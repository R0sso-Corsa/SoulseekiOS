import Foundation

/// App-level music share card for chat (AD-12). Encoded as a single text line
/// `slsk-music:{json}` — plain text to other Soulseek clients (interoperable),
/// rendered as a tappable download card by this app. Recipients pull the file
/// via the normal transfer flow; nothing is pushed.
public struct MusicCard: Equatable, Sendable {
    public static let prefix = "slsk-music:"

    public let username: String
    public let path: String
    public let size: UInt64

    public init(username: String, path: String, size: UInt64) {
        self.username = username
        self.path = path
        self.size = size
    }

    public var title: String {
        if let i = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            return String(path[path.index(after: i)...])
        }
        return path
    }

    public func encoded() -> String {
        let obj: [String: Any] = ["u": username, "p": path, "s": size]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else {
            return Self.prefix + "{}"
        }
        return Self.prefix + json
    }

    public static func parse(_ text: String) -> MusicCard? {
        guard text.hasPrefix(prefix) else { return nil }
        let json = String(text.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let u = obj["u"] as? String, !u.isEmpty,
              let p = obj["p"] as? String, !p.isEmpty else { return nil }
        let s: UInt64
        if let n = obj["s"] as? UInt64 { s = n }
        else if let n = obj["s"] as? Int, n >= 0 { s = UInt64(n) }
        else if let n = obj["s"] as? Double, n >= 0 { s = UInt64(n) }
        else { return nil }
        return MusicCard(username: u, path: p, size: s)
    }
}