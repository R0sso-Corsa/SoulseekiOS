import Foundation

/// One shared audio file: virtual Soulseek path → local file.
public struct SharedFile: Equatable, Sendable {
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

    private let storeURL: URL
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
        files[virtualPath]
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