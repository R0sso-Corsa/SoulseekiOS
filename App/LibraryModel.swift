import Foundation

/// Library of completed downloads (management only — playback is planned,
/// AD-15). Scans Documents/Downloads; .partial files are excluded.
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

    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case date = "Newest"
        case size = "Largest"
    }

    private(set) var files: [LibraryFile] = []
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
        var result: [LibraryFile] = []
        for url in urls where !url.lastPathComponent.hasSuffix(".partial") {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            result.append(LibraryFile(
                url: url,
                name: url.lastPathComponent,
                size: UInt64(values?.fileSize ?? 0),
                date: values?.contentModificationDate ?? .distantPast
            ))
        }
        switch sortOrder {
        case .name: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date: result.sort { $0.date > $1.date }
        case .size: result.sort { $0.size > $1.size }
        }
        files = result
    }

    func delete(_ file: LibraryFile) {
        try? FileManager.default.removeItem(at: file.url)
        refresh()
    }
}