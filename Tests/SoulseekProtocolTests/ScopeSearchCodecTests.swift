import Foundation
import XCTest
import SoulseekProtocol

/// UserSearch(42) and RoomSearch(120) — doc-verified payload order.
final class ScopeSearchCodecTests: XCTestCase {
    func testUserSearchGolden() {
        // username "alice", token 42, query "flac"
        let expected = Data(hex: "190000002a00000005000000616c6963652a00000004000000666c6163")
        XCTAssertEqual(ServerMessages.userSearch(username: "alice", ticket: 42, query: "flac"), expected)
    }

    func testRoomSearchGolden() {
        // room "jazz", token 7, query "mp3"
        let expected = Data(hex: "1700000078000000040000006a617a7a07000000030000006d7033")
        XCTAssertEqual(ServerMessages.roomSearch(room: "jazz", ticket: 7, query: "mp3"), expected)
    }
}

extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...hex.index(hex.startIndex, offsetBy: $0 + 1)], radix: 16)!
        })
    }
}