import XCTest
@testable import SoulseekProtocol

final class CodecTests: XCTestCase {
    /// Golden bytes computed independently (Python struct + hashlib) for user "a", pass "b".
    func testLoginGoldenBytes() {
        let frame = Login.frame(username: "a", password: "b")
        let expected = "3a0000000100000001000000610100000062af00000020000000313837656634343336313232643163633266343064633262393266306562613001000000"
        XCTAssertEqual(frame.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testFrameRoundTripAndPartialReads() throws {
        var w = MessageWriter()
        w.string("hello")
        w.u32(42)
        let frame = w.frame(code: 26)

        var r = FrameReader()
        r.append(frame.prefix(5))
        XCTAssertNil(try r.next())
        r.append(frame.dropFirst(5))
        let out = try XCTUnwrap(try r.next())
        XCTAssertEqual(out.code, 26)

        var mr = MessageReader(out.payload)
        XCTAssertEqual(try mr.string(), "hello")
        XCTAssertEqual(try mr.u32(), 42)
        XCTAssertEqual(mr.remaining, 0)
        XCTAssertNil(try r.next())
    }

    func testLoginResponseSuccess() throws {
        var w = MessageWriter()
        w.u8(1)
        w.string("welcome")
        w.u8(4); w.u8(3); w.u8(2); w.u8(1) // 1.2.3.4, least-significant octet first
        w.string("md5")
        w.u8(0)
        let resp = try LoginResponse(payload: Data(w.bytes))
        XCTAssertTrue(resp.success)
        XCTAssertEqual(resp.greeting, "welcome")
        XCTAssertEqual(resp.ip, "1.2.3.4")
        XCTAssertEqual(resp.passwordMD5, "md5")
        XCTAssertEqual(resp.privileged, false)
        XCTAssertNil(resp.reason)
    }

    func testLoginResponseFailure() throws {
        var w = MessageWriter()
        w.u8(0)
        w.string("INVALIDPASS")
        let resp = try LoginResponse(payload: Data(w.bytes))
        XCTAssertFalse(resp.success)
        XCTAssertEqual(resp.reason, "INVALIDPASS")
    }

    func testMD5() {
        XCTAssertEqual(md5Hex("ab"), "187ef4436122d1cc2f40dc2b92f0eba0")
    }
}