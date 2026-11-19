import XCTest
@testable import SoulseekProtocol

final class SearchCodecTests: XCTestCase {
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

    func testFileSearchGoldenBytes() {
        XCTAssertEqual(hex(ServerMessages.fileSearch(ticket: 42, query: "flac")),
                       "100000001a0000002a00000004000000666c6163")
    }

    func testPierceFirewallGoldenBytes() {
        XCTAssertEqual(hex(PeerInitMessages.pierceFirewall(ticket: 42)), "05000000002a000000")
    }

    func testPeerInitGoldenBytes() {
        XCTAssertEqual(hex(PeerInitMessages.peerInit(username: "ab", type: "P", ticket: 7)),
                       "1000000001020000006162010000005007000000")
    }

    func testCannotConnectGoldenBytes() {
        XCTAssertEqual(hex(ServerMessages.cannotConnect(ticket: 42, username: "x")),
                       "0d000000e90300002a0000000100000078")
    }

    func testConnectToPeerDecode() throws {
        let frame = data(hex: "2b0000001200000009000000726573706f6e646572010000005004030201ba0800002a000000000000000000000000")
        var reader = FrameReader()
        reader.append(frame)
        let f = try XCTUnwrap(try reader.next())
        XCTAssertEqual(f.code, 18)
        let req = try ConnectToPeerRequest(payload: f.payload)
        XCTAssertEqual(req.username, "responder")
        XCTAssertEqual(req.type, "P")
        XCTAssertEqual(req.ip, "1.2.3.4")
        XCTAssertEqual(req.port, 2234)
        XCTAssertEqual(req.ticket, 42)
        XCTAssertEqual(req.privileged, false)
    }

    /// Whole payload is zlib-compressed (verified: aioslsk + Nicotine+ agree).
    /// Fixture compressed independently with Python zlib.
    func testSearchReplyDecodeGoldenFixture() throws {
        let frame = data(hex: "8400000009000000789ce3646060284a2d2ec8cf4b492dd202729880985115483838e496166726c738169564169728e82a38e62495e6c618180299214589c9d97ab905c67e897b1840801988815c2606087060041a02a4bf820c53c3639811dcb0b49cc4e44b65fc3013c026828cd001122c40da650d03032b9016008b4f60042b80010090fb2419")
        var reader = FrameReader()
        reader.append(frame)
        let f = try XCTUnwrap(try reader.next())
        XCTAssertEqual(f.code, 9)
        let reply = try SearchReply(payload: f.payload)
        XCTAssertEqual(reply.username, "responder")
        XCTAssertEqual(reply.ticket, 42)
        XCTAssertEqual(reply.files.count, 2)
        XCTAssertEqual(reply.freeSlots, true)
        XCTAssertEqual(reply.avgSpeed, 102400)
        XCTAssertEqual(reply.queueSize, 3)

        let mp3 = reply.files[0]
        XCTAssertEqual(mp3.path, "@@music\\Artist - Album\\01 - Track.mp3")
        XCTAssertEqual(mp3.filename, "01 - Track.mp3")
        XCTAssertEqual(mp3.folder, "@@music\\Artist - Album")
        XCTAssertEqual(mp3.size, 12345678)
        XCTAssertEqual(mp3.ext, "mp3")
        XCTAssertEqual(mp3.bitrate, 320)
        XCTAssertEqual(mp3.duration, 245)

        let flac = reply.files[1]
        XCTAssertEqual(flac.ext, "flac", "blank extension must be derived from the path")
        XCTAssertEqual(flac.size, 34567890)
        XCTAssertEqual(flac.duration, 300)
        XCTAssertEqual(flac.sampleRate, 44100)
        XCTAssertEqual(flac.bitness, 16)
        XCTAssertNil(flac.bitrate)
    }

    func testZlibRoundTrip() throws {
        let original = Data("the quick brown fox jumps over the lazy dog".utf8)
        let compressed = try Zlib.deflate(original)
        XCTAssertEqual(try Zlib.inflate(compressed), original)
    }

    func testZlibInflateRejectsGarbage() {
        XCTAssertThrowsError(try Zlib.inflate(Data([0x00, 0x01, 0x02, 0x03])))
    }

    func testParseInitFrame() throws {
        let frame = PeerInitMessages.peerInit(username: "ab", type: "P", ticket: 7)
        let parsed = try XCTUnwrap(try PeerInitMessages.parseInitFrame(frame))
        XCTAssertEqual(parsed.code, 1)
        XCTAssertEqual(parsed.consumed, frame.count)
        var r = MessageReader(parsed.payload)
        XCTAssertEqual(try r.string(), "ab")
        XCTAssertEqual(try r.string(), "P")
        XCTAssertEqual(try r.u32(), 7)
    }
}