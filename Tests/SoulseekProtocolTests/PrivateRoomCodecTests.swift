import Foundation
import XCTest
import SoulseekProtocol

final class PrivateRoomCodecTests: XCTestCase {
    func testSendGoldens() {
        XCTAssertEqual(ServerMessages.addRoomMember(room: "vault", username: "bob"),
                       Data(hex: "1400000086000000050000007661756c7403000000626f62"))
        XCTAssertEqual(ServerMessages.removeRoomMember(room: "vault", username: "bob"),
                       Data(hex: "1400000087000000050000007661756c7403000000626f62"))
        XCTAssertEqual(ServerMessages.cancelRoomMembership(room: "vault"),
                       Data(hex: "0d00000088000000050000007661756c74"))
        XCTAssertEqual(ServerMessages.cancelRoomOwnership(room: "vault"),
                       Data(hex: "0d00000089000000050000007661756c74"))
        XCTAssertEqual(ServerMessages.enableRoomInvitations(true),
                       Data(hex: "050000008d00000001"))
        XCTAssertEqual(ServerMessages.addRoomOperator(room: "vault", username: "bob"),
                       Data(hex: "140000008f000000050000007661756c7403000000626f62"))
        XCTAssertEqual(ServerMessages.removeRoomOperator(room: "vault", username: "bob"),
                       Data(hex: "1400000090000000050000007661756c7403000000626f62"))
    }

    func testRoomMembersParse() throws {
        let m = try RoomMembers(payload: Data(hex: "2100000085000000050000007661756c740200000005000000616c69636503000000626f62").dropFirst(8))
        XCTAssertEqual(m.room, "vault")
        XCTAssertEqual(m.members, ["alice", "bob"])
    }

    func testRoomOperatorsParse() throws {
        let o = try RoomOperators(payload: Data(hex: "1a00000094000000050000007661756c740100000005000000616c696365").dropFirst(8))
        XCTAssertEqual(o.room, "vault")
        XCTAssertEqual(o.operators, ["alice"])
    }
}