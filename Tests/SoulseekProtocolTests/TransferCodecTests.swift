import XCTest
@testable import SoulseekProtocol

final class TransferCodecTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func data(hex: String) -> Data {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            bytes.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        return Data(bytes)
    }

    private func framePayload(_ hexString: String) throws -> Data {
        var reader = FrameReader()
        reader.append(data(hex: hexString))
        return try XCTUnwrap(try reader.next()).payload
    }

    func testQueueDownloadGoldenBytes() {
        XCTAssertEqual(hex(PeerMessages.queueDownload(filename: "@@music\\x.mp3")),
                       "150000002b0000000d00000040406d757369635c782e6d7033")
    }

    func testTransferReplyAllowedGoldenBytes() {
        XCTAssertEqual(hex(PeerMessages.transferReply(ticket: 7, allowed: true, filesize: 100)),
                       "110000002900000007000000016400000000000000")
    }

    func testTransferReplyDeniedGoldenBytes() {
        XCTAssertEqual(hex(PeerMessages.transferReply(ticket: 7, allowed: false, reason: "Cancelled")),
                       "160000002900000007000000000900000043616e63656c6c6564")
    }

    func testTransferRequestDecode() throws {
        let payload = try framePayload("250000002800000001000000070000000d00000040406d757369635c782e6d70336400000000000000")
        let req = try TransferRequest(payload: payload)
        XCTAssertEqual(req.direction, 1)
        XCTAssertEqual(req.ticket, 7)
        XCTAssertEqual(req.filename, "@@music\\x.mp3")
        XCTAssertEqual(req.filesize, 100)
    }

    func testTransferRequestDecodeOmittedSize() throws {
        var w = MessageWriter()
        w.u32(1); w.u32(9); w.string("f.mp3")
        let req = try TransferRequest(payload: Data(w.bytes))
        XCTAssertEqual(req.ticket, 9)
        XCTAssertNil(req.filesize, "direction=1 may omit filesize")
    }

    func testPlaceInQueueReplyDecode() throws {
        let payload = try framePayload("190000002c0000000d00000040406d757369635c782e6d703303000000")
        let reply = try PlaceInQueueReply(payload: payload)
        XCTAssertEqual(reply.filename, "@@music\\x.mp3")
        XCTAssertEqual(reply.place, 3)
    }

    func testTransferQueueFailedDecode() throws {
        let payload = try framePayload("28000000320000000d00000040406d757369635c782e6d70330f00000046696c65206e6f7420736861726564")
        let failed = try TransferQueueFailed(payload: payload)
        XCTAssertEqual(failed.filename, "@@music\\x.mp3")
        XCTAssertEqual(failed.reason, "File not shared")
    }

    func testGetPeerAddressGoldenBytes() {
        XCTAssertEqual(hex(ServerMessages.getPeerAddress(username: "bob")),
                       "0b0000000300000003000000626f62")
    }

    func testPeerAddressReplyDecode() throws {
        let payload = try framePayload("190000000300000003000000626f6204030201ba080000000000000000")
        let reply = try PeerAddressReply(payload: payload)
        XCTAssertEqual(reply.username, "bob")
        XCTAssertEqual(reply.ip, "1.2.3.4")
        XCTAssertEqual(reply.port, 2234)
    }

    func testUserInfoRequestGoldenBytes() {
        XCTAssertEqual(hex(PeerMessages.userInfoRequest()), "040000000f000000")
    }

    func testPlaceInQueueRequestGoldenBytes() {
        XCTAssertEqual(hex(PeerMessages.placeInQueueRequest(filename: "@@music\\x.mp3")),
                       "15000000330000000d00000040406d757369635c782e6d7033")
    }
}