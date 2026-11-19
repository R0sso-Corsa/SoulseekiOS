import XCTest
@testable import SoulseekProtocol

/// Chat codec: private messages (22/23), rooms (13/14/15/16/17/64), and the
/// app-level music share card. Goldens generated with Python struct (2026-11-19).
final class ChatCodecTests: XCTestCase {
    func testMessageUserGolden() throws {
        XCTAssertEqual(ServerMessages.messageUser(username: "alice", message: "hey there").hexString,
                       "1a0000001600000005000000616c69636509000000686579207468657265")
    }

    func testPrivateMessageDecode() throws {
        let pm = try PrivateMessage(payload: Data(hexString: "4d00000000f1536505000000616c6963650900000068657920746865726501"))
        XCTAssertEqual(pm.id, 77)
        XCTAssertEqual(pm.timestamp, 1_700_000_000)
        XCTAssertEqual(pm.username, "alice")
        XCTAssertEqual(pm.message, "hey there")
        XCTAssertTrue(pm.isNew)
    }

    func testMessageAckedGolden() throws {
        XCTAssertEqual(ServerMessages.messageAcked(id: 77).hexString, "08000000170000004d000000")
    }

    func testSayInRoomGolden() throws {
        XCTAssertEqual(ServerMessages.sayInRoom(room: "jazz", message: "hello room").hexString,
                       "1a0000000d000000040000006a617a7a0a00000068656c6c6f20726f6f6d")
    }

    func testRoomMessageDecode() throws {
        let rm = try RoomMessage(payload: Data(hexString: "040000006a617a7a03000000626f6206000000686920616c6c"))
        XCTAssertEqual(rm.room, "jazz")
        XCTAssertEqual(rm.username, "bob")
        XCTAssertEqual(rm.message, "hi all")
    }

    func testJoinRoomGolden() throws {
        XCTAssertEqual(ServerMessages.joinRoom(room: "jazz", type: 0).hexString,
                       "100000000e000000040000006a617a7a00000000")
    }

    func testRoomJoinedDecode() throws {
        let joined = try RoomJoined(payload: Data(hexString: "040000006a617a7a0200000005000000616c69636503000000626f6202000000020000000100000002000000e80300000500000000000000640000000a000000d00700000900000000000000c80000001400000002000000000000000100000002000000020000005553020000004445"))
        XCTAssertEqual(joined.room, "jazz")
        XCTAssertEqual(joined.members.count, 2)
        XCTAssertEqual(joined.members[0].username, "alice")
        XCTAssertEqual(joined.members[0].status, 2)
        XCTAssertEqual(joined.members[0].avgSpeed, 1000)
        XCTAssertEqual(joined.members[0].files, 100)
        XCTAssertEqual(joined.members[0].folders, 10)
        XCTAssertEqual(joined.members[0].country, "US")
        XCTAssertEqual(joined.members[1].username, "bob")
        XCTAssertEqual(joined.members[1].status, 1)
        XCTAssertEqual(joined.members[1].slotsFull, true)
        XCTAssertEqual(joined.members[1].country, "DE")
        XCTAssertNil(joined.owner)
    }

    func testLeaveRoomGolden() throws {
        XCTAssertEqual(ServerMessages.leaveRoom(room: "jazz").hexString,
                       "0c0000000f000000040000006a617a7a")
    }

    func testUserJoinedRoomDecode() throws {
        let uj = try UserJoinedRoom(payload: Data(hexString: "040000006a617a7a050000006361726f6c02000000b80b000001000000000000002c0100001e00000000000000020000004652"))
        XCTAssertEqual(uj.room, "jazz")
        XCTAssertEqual(uj.member.username, "carol")
        XCTAssertEqual(uj.member.avgSpeed, 3000)
        XCTAssertEqual(uj.member.files, 300)
        XCTAssertEqual(uj.member.country, "FR")
    }

    func testUserLeftRoomDecode() throws {
        let ul = try UserLeftRoom(payload: Data(hexString: "040000006a617a7a03000000626f62"))
        XCTAssertEqual(ul.room, "jazz")
        XCTAssertEqual(ul.username, "bob")
    }

    func testRoomListGoldenAndDecode() throws {
        XCTAssertEqual(ServerMessages.roomList().hexString, "0400000040000000")
        let list = try RoomList(payload: Data(hexString: "01000000040000006a617a7a010000002a00000001000000070000006d7967726f75700100000003000000000000000000000000000000"))
        XCTAssertEqual(list.publicRooms.count, 1)
        XCTAssertEqual(list.publicRooms[0].name, "jazz")
        XCTAssertEqual(list.publicRooms[0].userCount, 42)
        XCTAssertEqual(list.ownedPrivateRooms.count, 1)
        XCTAssertEqual(list.ownedPrivateRooms[0].name, "mygroup")
        XCTAssertEqual(list.ownedPrivateRooms[0].userCount, 3)
        XCTAssertTrue(list.privateRooms.isEmpty)
        XCTAssertTrue(list.operatedRooms.isEmpty)
    }

    func testMusicCardRoundTrip() throws {
        let card = MusicCard(username: "alice", path: "@@music\\Album\\01 Song.flac", size: 123_456)
        let text = card.encoded()
        XCTAssertTrue(text.hasPrefix("slsk-music:"))
        let parsed = try XCTUnwrap(MusicCard.parse(text))
        XCTAssertEqual(parsed, card)
        XCTAssertEqual(parsed.title, "01 Song.flac")
        // Plain text and malformed payloads are not cards.
        XCTAssertNil(MusicCard.parse("hello world"))
        XCTAssertNil(MusicCard.parse("slsk-music:not json"))
        XCTAssertNil(MusicCard.parse("slsk-music:{\"u\":\"alice\"}"))
    }
}