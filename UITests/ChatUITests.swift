import XCTest

/// Opt-in live acceptance: search → Chat tab → create a group → send a
/// message (server echoes it back) → share a music card from search results
/// → card renders with a download button. Single account; the two-account
/// delivery + download path is proven by LiveChatTests in the Core suite.
final class ChatUITests: XCTestCase {
    func testLiveGroupChatAndMusicShare() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live chat UI test is opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetCredentials"]
        app.launch()

        let userField = app.textFields["usernameField"]
        XCTAssertTrue(userField.waitForExistence(timeout: 15), "login screen missing")
        userField.tap()
        userField.typeText(user)
        let passField = app.secureTextFields["passwordField"]
        passField.tap()
        passField.typeText(pass)
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "login did not complete")

        // Search first so the share picker has results.
        app.tapTab("Search")
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("mp3")
        app.buttons["searchButton"].tap()
        XCTAssertTrue(app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90), "no search results")

        // Chat tab → create a group.
        app.tapTab("Chat")
        let plus = app.buttons["newChatButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "chat tab missing")
        plus.tap()
        let newRoomItem = app.buttons["Create / join group"]
        XCTAssertTrue(newRoomItem.waitForExistence(timeout: 10), "menu did not open")
        newRoomItem.tap()
        let alert = app.alerts["Create or join a group"]
        if !alert.waitForExistence(timeout: 10) {
            let failShot = XCUIScreen.main.screenshot()
            let failAtt = XCTAttachment(screenshot: failShot)
            failAtt.name = "room-alert-FAILURE"
            failAtt.lifetime = .keepAlways
            add(failAtt)
            XCTFail("room alert missing")
        }
        let roomName = "SlskIosUI" + String(Int.random(in: 100...999))
        let roomField = alert.textFields.firstMatch
        roomField.tap()
        roomField.typeText(roomName)
        alert.buttons["Join / Create"].firstMatch.tap()

        // Conversation opens; send a message and wait for the server echo.
        let messageField = app.textFields["messageField"]
        XCTAssertTrue(messageField.waitForExistence(timeout: 15), "conversation did not open")
        messageField.tap()
        messageField.typeText("hello from the iOS client")
        app.buttons["sendButton"].tap()
        let ownBubble = app.staticTexts["hello from the iOS client"]
        XCTAssertTrue(ownBubble.waitForExistence(timeout: 20), "own message never echoed back")

        // Share music: ♪ → picker → first file → card renders.
        app.buttons["shareMusicButton"].tap()
        let fileRow = app.buttons["shareFileRow"].firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 15), "share picker empty")
        fileRow.tap()
        let card = app.staticTexts["musicCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "music card never appeared")
        XCTAssertTrue(app.buttons["cardDownloadButton"].firstMatch.exists, "card download button missing")

        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "chat-state"
        att.lifetime = .keepAlways
        add(att)

        // Leave the room to clean up (via the ⋯ actions menu).
        app.buttons["roomActionsMenu"].tap()
        let leave = app.buttons["leaveRoomButton"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5), "leave action missing")
        leave.tap()
    }
}