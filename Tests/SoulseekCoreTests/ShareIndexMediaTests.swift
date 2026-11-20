import Foundation
import XCTest
@testable import SoulseekCore

/// AD-16 sender side: chat media registers into the ShareIndex (reachable by
/// exact path for uploads, hidden from browse/counts) and persists.
final class ShareIndexMediaTests: XCTestCase {
    func testRegisterMediaLookupAndPersistence() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("pic.jpg")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        try bytes.write(to: file)
        let store = tmp.appendingPathComponent("shares.json")

        let index = ShareIndex(storeURL: store)
        await index.registerMedia(virtualPath: "ChatMedia\\pic.jpg", localPath: file.path, size: UInt64(bytes.count))
        let found = await index.file(for: "ChatMedia\\pic.jpg")
        XCTAssertEqual(found?.localPath, file.path)
        XCTAssertEqual(found?.size, UInt64(bytes.count))
        // Not part of the public share surface.
        let files = await index.files
        XCTAssertNil(files["ChatMedia\\pic.jpg"])
        let folders = await index.folderCount
        XCTAssertEqual(folders, 0)

        // A fresh instance (app relaunch) restores the registry.
        let index2 = ShareIndex(storeURL: store)
        let again = await index2.file(for: "ChatMedia\\pic.jpg")
        XCTAssertEqual(again?.localPath, file.path)

        // Unregister removes it (TTL cleanup path).
        await index2.unregisterMedia(virtualPath: "ChatMedia\\pic.jpg")
        let gone = await index2.file(for: "ChatMedia\\pic.jpg")
        XCTAssertNil(gone)
    }

    func testMissingLocalFileDroppedOnLoad() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = tmp.appendingPathComponent("shares.json")
        let index = ShareIndex(storeURL: store)
        await index.registerMedia(virtualPath: "ChatMedia\\gone.jpg", localPath: tmp.appendingPathComponent("gone.jpg").path, size: 10)
        let index2 = ShareIndex(storeURL: store)
        let found = await index2.file(for: "ChatMedia\\gone.jpg")
        XCTAssertNil(found, "registry entries whose file vanished must be dropped")
    }
}