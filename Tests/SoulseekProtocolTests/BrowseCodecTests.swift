import XCTest
@testable import SoulseekProtocol

/// Browse shares + user info codec. Goldens generated independently with
/// Python struct/zlib (2026-11-19). Layouts per Nicotine+ SLSKPROTOCOL.md:
/// peer 4 empty request, peer 5 zlib-compressed folder list (+ unknown +
/// private folders tolerated), server 36 stats, server 7 status.
final class BrowseCodecTests: XCTestCase {
    func testSharedFileListRequestGolden() throws {
        XCTAssertEqual(PeerMessages.sharedFileListRequest().hexString,
                       "0400000004000000")
    }

    func testSharedFileListDecode() throws {
        let frame = Data(hexString: "4300000005000000789c63646060e00662dfd2e2cce418c79ca4d25c4620979113489414252667ebe516183b3c0289313030033190cbc400010e405190c40906040000267b0afb")
        var reader = MessageReader(frame)
        _ = try reader.u32() // frame length
        let code = try reader.u32()
        XCTAssertEqual(code, 5)
        let list = try SharedFileList(payload: reader.rest())
        XCTAssertEqual(list.folders.count, 1)
        XCTAssertEqual(list.folders[0].path, "Music\\Album")
        XCTAssertEqual(list.folders[0].files.count, 1)
        let file = list.folders[0].files[0]
        XCTAssertEqual(file.path, "track.mp3") // basename; folder is separate
        XCTAssertEqual(file.size, 123456)
        XCTAssertEqual(file.ext, "mp3")
        XCTAssertEqual(file.bitrate, 320)
        XCTAssertEqual(file.duration, 200)
    }

    func testSharedFileListRejectsGarbage() {
        XCTAssertThrowsError(try SharedFileList(payload: Data([0x00, 0x01, 0x02])))
    }

    func testGetUserStatsGolden() throws {
        XCTAssertEqual(ServerMessages.getUserStats(username: "alice").hexString,
                       "0d0000002400000005000000616c696365")
        let stats = try UserStats(payload: Data(hexString: "05000000616c69636550c30000d2040000000000002c01000014000000"))
        XCTAssertEqual(stats.username, "alice")
        XCTAssertEqual(stats.avgSpeed, 50000)
        XCTAssertEqual(stats.uploadCount, 1234)
        XCTAssertEqual(stats.files, 300)
        XCTAssertEqual(stats.folders, 20)
    }

    func testGetUserStatusGolden() throws {
        XCTAssertEqual(ServerMessages.getUserStatus(username: "alice").hexString,
                       "0d0000000700000005000000616c696365")
        let status = try UserStatus(payload: Data(hexString: "05000000616c6963650200000001"))
        XCTAssertEqual(status.username, "alice")
        XCTAssertEqual(status.status, .online)
        XCTAssertTrue(status.privileged)
        let away = try UserStatus(payload: Data(hexString: "05000000616c6963650100000000"))
        XCTAssertEqual(away.status, .away)
        XCTAssertFalse(away.privileged)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    init(hexString: String) {
        self.init(stride(from: 0, to: hexString.count, by: 2).map {
            UInt8(hexString.dropFirst($0).prefix(2), radix: 16)!
        })
    }
}