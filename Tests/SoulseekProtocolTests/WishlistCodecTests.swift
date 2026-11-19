import XCTest
@testable import SoulseekProtocol

final class WishlistCodecTests: XCTestCase {
    func testWishlistSearchGolden() throws {
        XCTAssertEqual(ServerMessages.wishlistSearch(ticket: 42, query: "flac").hexString,
                       "10000000670000002a00000004000000666c6163")
    }

    func testWishlistIntervalDecode() throws {
        XCTAssertEqual(try WishlistInterval(payload: Data(hexString: "d0020000")).seconds, 720)
    }
}