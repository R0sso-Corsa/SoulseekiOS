import Foundation

/// Library of completed downloads: grouped by album (original Soulseek
/// folder, from the download manifest), preview playback, management.
@MainActor
@Observable
final class LibraryModel {
    struct LibraryFile: Identifiable, Equatable {
        let url: URL
        let name: String
        let size: UInt64
        let date: Date
        var id: URL { url }
    }

    struct Album: Identifiable, Equatable {
        let name: String
        let files: [LibraryFile]
        var id: String { name }
        var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
    }

    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case date = "Newest"
        case size = "Largest"
    }

    private(set) var files: [LibraryFile] = []
    private(set) var albums: [Album] = []
    var sortOrder: SortOrder = .date { didSet { refresh() } }
    var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let manifestURL = directory.appendingPathComponent(".downloads-manifest.json")
        let manifest = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))) ?? [:]
        var result: [LibraryFile] = []
        var grouped: [String: [LibraryFile]] = [:]
        for url in urls where !url.lastPathComponent.hasSuffix(".partial") && !url.lastPathComponent.hasPrefix(".") {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let file = LibraryFile(
                url: url,
                name: url.lastPathComponent,
                size: UInt64(values?.fileSize ?? 0),
                date: values?.contentModificationDate ?? .distantPast
            )
            result.append(file)
            grouped[Self.albumName(for: file.name, manifest: manifest), default: []].append(file)
        }
        switch sortOrder {
        case .name: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date: result.sort { $0.date > $1.date }
        case .size: result.sort { $0.size > $1.size }
        }
        files = result
        albums = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
            Album(name: name, files: grouped[name]!.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        }
    }

    /// Album = the folder above the track in the original Soulseek path.
    /// Files without a manifest entry (older downloads) land in "Singles".
    static func albumName(for storedName: String, manifest: [String: String]) -> String {
        guard let original = manifest[storedName] else { return "Singles" }
        let parts = original.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        guard parts.count >= 2 else { return "Singles" }
        return String(parts[parts.count - 2])
    }

    func delete(_ file: LibraryFile) {
        try? FileManager.default.removeItem(at: file.url)
        refresh()
    }

    func deleteAlbum(_ album: Album) {
        for file in album.files {
            try? FileManager.default.removeItem(at: file.url)
        }
        refresh()
    }
}