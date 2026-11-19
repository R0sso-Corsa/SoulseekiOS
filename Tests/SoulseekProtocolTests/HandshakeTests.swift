import XCTest
@testable import SoulseekProtocol

final class HandshakeTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Full post-login handshake for a receive-only client, username "ab".
    /// Order per aioslsk "Server Connection and Logon"; golden bytes computed
    /// independently with Python struct.
    func testHandshakeSequenceGoldenBytes() {
        let frames = Handshake.frames(username: "ab")
        let expected = [
            "040000005c000000",                         // CheckPrivileges(92)
            "1000000002000000000000000000000000000000", // SetListenPort(2): port 0, no obfuscation
            "080000001c00000002000000",                 // SetStatus(28): online
            "0c000000230000000000000000000000",         // SharedFoldersFiles(35): 0 folders, 0 files
            "0a00000005000000020000006162",             // AddUser(5): self
            "050000004700000000",                       // ToggleParentSearch(71): false
            "0a0000007f000000020000006162",             // BranchRoot(127): self
            "080000007e00000000000000",                 // BranchLevel(126): 0
            "050000006400000000",                       // AcceptChildren(100): false
        ]
        XCTAssertEqual(frames.map(hex), expected)
    }

    func testSetListenPortEncodesPortAndZeroObfuscation() {
        XCTAssertEqual(hex(ServerMessages.setListenPort(2234)),
                       "1000000002000000ba0800000000000000000000")
    }

    func testSharedFoldersFilesEncodesFoldersThenFiles() {
        XCTAssertEqual(hex(ServerMessages.sharedFoldersFiles(folders: 3, files: 7)),
                       "0c000000230000000300000007000000")
    }

    func testSetStatusEncodesAway() {
        XCTAssertEqual(hex(ServerMessages.setStatus(1)), "080000001c00000001000000")
    }

    func testAcceptChildrenTrue() {
        XCTAssertEqual(hex(ServerMessages.acceptChildren(true)), "050000006400000001")
    }

    func testBranchLevelEncodesLevel() {
        XCTAssertEqual(hex(ServerMessages.branchLevel(5)), "080000007e00000005000000")
    }

    func testPingAndCheckPrivilegesHaveNoPayload() {
        XCTAssertEqual(hex(ServerMessages.ping()), "0400000020000000")
        XCTAssertEqual(hex(ServerMessages.checkPrivileges()), "040000005c000000")
    }
}