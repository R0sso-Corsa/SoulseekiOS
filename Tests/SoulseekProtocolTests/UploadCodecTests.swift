import XCTest
@testable import SoulseekProtocol

/// Upload-side codec: QueueFailed(50), PlaceInQueueReply(44),
/// SharedFoldersFiles(35), SendUploadSpeed(121). Goldens via Python struct.
final class UploadCodecTests: XCTestCase {
    func testQueueFailedGolden() throws {
        XCTAssertEqual(PeerMessages.queueFailed(filename: "a\\b.mp3", reason: "File not shared.").hexString,
                       "230000003200000007000000615c622e6d70331000000046696c65206e6f74207368617265642e")
    }

    func testPlaceInQueueReplyGolden() throws {
        XCTAssertEqual(PeerMessages.placeInQueueReply(filename: "a\\b.mp3", place: 3).hexString,
                       "130000002c00000007000000615c622e6d703303000000")
    }

    func testSharedFoldersFilesGolden() throws {
        XCTAssertEqual(ServerMessages.sharedFoldersFiles(folders: 5, files: 120).hexString,
                       "0c000000230000000500000078000000")
    }

    func testSendUploadSpeedGolden() throws {
        XCTAssertEqual(ServerMessages.sendUploadSpeed(50000).hexString,
                       "080000007900000050c30000")
    }
}