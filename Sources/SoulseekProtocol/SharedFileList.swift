import Foundation

/// One shared folder from a browse response. File paths are BASENAMES;
/// join with `path` (Windows-style separator) for the full download name.
public struct SharedFolder: Equatable, Sendable {
    public let path: String
    public let files: [FileEntry]
}

/// SharedFileListResponse (peer code 5). ENTIRE payload zlib-compressed
/// (doc-verified 2026-11-19). Decompressed: u32 folder count; per folder:
/// string path, u32 file count, FileData entries. Trailing unknown u32 +
/// private folders (buddy-only) are tolerated and ignored.
public struct SharedFileList: Equatable, Sendable {
    public let folders: [SharedFolder]

    public init(payload: Data) throws {
        let raw = try Zlib.inflate(payload)
        var r = MessageReader(raw)
        let folderCount = try r.u32()
        guard folderCount <= 100_000 else { throw CodecError.truncated }
        var result: [SharedFolder] = []
        result.reserveCapacity(Int(folderCount))
        for _ in 0..<folderCount {
            let path = try r.string()
            let fileCount = try r.u32()
            guard fileCount <= 1_000_000 else { throw CodecError.truncated }
            var files: [FileEntry] = []
            files.reserveCapacity(Int(fileCount))
            for _ in 0..<fileCount {
                files.append(try FileEntry(reader: &r))
            }
            result.append(SharedFolder(path: path, files: files))
        }
        folders = result
    }
}