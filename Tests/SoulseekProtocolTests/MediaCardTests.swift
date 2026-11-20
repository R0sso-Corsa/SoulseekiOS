import Foundation
import XCTest
import SoulseekProtocol

final class MediaCardTests: XCTestCase {
    func testImageRoundTrip() throws {
        let card = MediaCard(username: "alice", path: "ChatMedia\\abc123.jpg", size: 245_000, kind: .image, ext: "jpg")
        let line = card.encoded()
        XCTAssertTrue(line.hasPrefix("slsk-media:"))
        let back = try XCTUnwrap(MediaCard.parse(line))
        XCTAssertEqual(back, card)
        XCTAssertEqual(back.title, "abc123.jpg")
    }

    func testVideoRoundTrip() throws {
        let card = MediaCard(username: "bob", path: "ChatMedia\\clip.mp4", size: 9_500_000, kind: .video, ext: "mp4")
        let back = try XCTUnwrap(MediaCard.parse(card.encoded()))
        XCTAssertEqual(back, card)
        XCTAssertEqual(back.kind, .video)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(MediaCard.parse("hello world"))
        XCTAssertNil(MediaCard.parse("slsk-media:not json"))
        XCTAssertNil(MediaCard.parse("slsk-media:{}"))
        XCTAssertNil(MediaCard.parse("slsk-media:{\"u\":\"a\",\"p\":\"p\",\"s\":1,\"t\":\"audio\"}"))
        XCTAssertNil(MediaCard.parse("slsk-music:{\"u\":\"a\",\"p\":\"p\",\"s\":1}"))
    }

    func testSizeNumberTolerance() throws {
        let card = try XCTUnwrap(MediaCard.parse("slsk-media:{\"u\":\"a\",\"p\":\"p\",\"s\":12.0,\"t\":\"image\",\"e\":\"png\"}"))
        XCTAssertEqual(card.size, 12)
    }

    func testDistinctFromMusicCard() {
        let media = MediaCard(username: "a", path: "p.jpg", size: 1, kind: .image, ext: "jpg")
        XCTAssertNil(MusicCard.parse(media.encoded()))
    }
}