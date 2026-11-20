import Foundation

/// One shared audio file: virtual Soulseek path → local file.
public struct SharedFile: Equatable, Sendable, Codable {
    public let virtualPath: String
    public let localPath: String
    public let size: UInt64
}

/// Scans user-picked folders into a virtual share tree. Virtual paths are
/// Windows-style: `<root folder name>\<relative path>`. Roots persist as JSON.
public actor ShareIndex {
    public private(set) var roots: [String] = []
    public private(set) var files: [String: SharedFile] = [:]
    public private(set) var folderCount: Int = 0
    /// Chat media attachments (AD-16): reachable by exact virtual path from
    /// the card, but NOT listed in browse/share counts — private to the chat.
    public private(set) var mediaFiles: [String: SharedFile] = [:]

    private let storeURL: URL
    private nonisolated var mediaStoreURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("chat-media.json")
    }
    private static let audioExtensions: Set<String> = [
        "mp3", "flac", "wav", "m4a", "aac", "ogg", "wma", "ape", "wv", "alac", "aiff", "opus",
    ]

    public init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            roots = saved
        }
        let scanned = Self.scan(roots)
        files = scanned.0
        folderCount = scanned.1
        if let data = try? Data(contentsOf: mediaStoreURL),
           let saved = try? JSONDecoder().decode([String: SharedFile].self, from: data) {
            mediaFiles = saved.filter { FileManager.default.fileExists(atPath: $0.value.localPath) }
        }
    }

    /// Register a chat-media file for upload (sender side of AD-16).
    public func registerMedia(virtualPath: String, localPath: String, size: UInt64) {
        mediaFiles[virtualPath] = SharedFile(virtualPath: virtualPath, localPath: localPath, size: size)
        saveMedia()
    }

    public func unregisterMedia(virtualPath: String) {
        mediaFiles[virtualPath] = nil
        saveMedia()
    }

    private func saveMedia() {
        if let data = try? JSONEncoder().encode(mediaFiles) {
            try? data.write(to: mediaStoreURL, options: .atomic)
        }
    }

    public func addRoot(_ path: String) {
        guard !roots.contains(path), FileManager.default.fileExists(atPath: path) else { return }
        roots.append(path)
        let scanned = Self.scan(roots)
        files = scanned.0
        folderCount = scanned.1
        save()
    }

    public func removeRoot(_ path: String) {
        roots.removeAll { $0 == path }
        let scanned = Self.scan(roots)
        files = scanned.0
        folderCount = scanned.1
        save()
    }

    public func file(for virtualPath: String) -> SharedFile? {
        files[virtualPath] ?? mediaFiles[virtualPath]
    }

    private static func scan(_ roots: [String]) -> ([String: SharedFile], Int) {
        var result: [String: SharedFile] = [:]
        var folders = Set<String>()
        for root in roots {
            let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            guard let en = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let rootName = rootURL.lastPathComponent
            for case let url as URL in en {
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if vals?.isDirectory == true { continue }
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let rel = url.resolvingSymlinksInPath().path.replacingOccurrences(of: rootURL.path + "/", with: "")
                let virtual = rootName + "\\" + rel.replacingOccurrences(of: "/", with: "\\")
                result[virtual] = SharedFile(virtualPath: virtual, localPath: url.path, size: UInt64(vals?.fileSize ?? 0))
                folders.insert((virtual as NSString).deletingLastPathComponent)
            }
        }
        return (result, folders.count)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(roots) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}