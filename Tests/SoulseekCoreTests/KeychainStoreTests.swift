import XCTest
@testable import SoulseekCore

final class KeychainStoreTests: XCTestCase {
    func testSaveLoadUpdateDeleteRoundTrip() throws {
        let store = KeychainStore(service: "slsk-test-\(UUID().uuidString)")
        XCTAssertNil(try store.load())

        try store.save(username: "tester", password: "secret")
        let loaded = try store.load()
        XCTAssertEqual(loaded?.username, "tester")
        XCTAssertEqual(loaded?.password, "secret")

        try store.save(username: "tester2", password: "secret2")
        let updated = try store.load()
        XCTAssertEqual(updated?.username, "tester2")
        XCTAssertEqual(updated?.password, "secret2")

        try store.delete()
        XCTAssertNil(try store.load())
    }
}