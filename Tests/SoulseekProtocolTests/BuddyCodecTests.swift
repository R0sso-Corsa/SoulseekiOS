import Foundation
import XCTest
import SoulseekProtocol

final class BuddyCodecTests: XCTestCase {
    func testWatchUserSendGolden() {
        XCTAssertEqual(ServerMessages.watchUser("alice"),
                       Data(hex: "0d0000000500000005000000616c696365"))
    }

    func testUnwatchUserSendGolden() {
        XCTAssertEqual(ServerMessages.unwatchUser("alice"),
                       Data(hex: "0d0000000600000005000000616c696365"))
    }

    func testWatchUserReplyGolden() throws {
        let reply = try WatchUserReply(payload: Data(hex: "2c0000000500000005000000616c6963650102000000e80300000500000000000000640000000a000000020000004742").dropFirst(8))
        XCTAssertEqual(reply.username, "alice")
        XCTAssertTrue(reply.exists)
        XCTAssertEqual(reply.status, 2)
        XCTAssertEqual(reply.avgSpeed, 1000)
        XCTAssertEqual(reply.uploadCount, 5)
        XCTAssertEqual(reply.files, 100)
        XCTAssertEqual(reply.folders, 10)
        XCTAssertEqual(reply.country, "GB")
    }

    func testWatchUserReplyNonexistent() throws {
        let reply = try WatchUserReply(payload: Data(hex: "0c0000000500000003000000626f6200").dropFirst(8))
        XCTAssertEqual(reply.username, "bob")
        XCTAssertFalse(reply.exists)
        XCTAssertNil(reply.status)
    }
}