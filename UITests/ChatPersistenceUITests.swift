import XCTest

/// Chats and groups must survive an app restart: create a group, send a
/// message, terminate, relaunch — the conversation and its history are back.
final class ChatPersistenceUITests: XCTestCase {
    func testChatPersistsAcrossRelaunch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live persistence UI test is opt-in")
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
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "login failed")

        // Create a group and send a message (server echoes it back).
        app.tapTab("Chat")
        let room = "SlskPersist" + String(Int.random(in: 1000...9999))
        let marker = "persist check \(Int.random(in: 100...999))"
        let plus = app.buttons["newChatButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        app.buttons["Create / join group"].tap()
        let alert = app.alerts["Create or join a group"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText(room)
        alert.buttons.matching(identifier: "Join / Create").firstMatch.tap()
        XCTAssertTrue(app.buttons["roomActionsMenu"].waitForExistence(timeout: 25), "room view missing")

        let composer = app.textFields["messageField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer missing")
        composer.tap()
        composer.typeText(marker)
        app.buttons["sendButton"].tap()
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 20), "message echo missing")

        // Terminate + relaunch (fresh instance, no credential reset).
        app.terminate()
        let app2 = XCUIApplication()
        app2.launch()
        XCTAssertTrue(app2.textFields["usernameField"].waitForNonExistence(timeout: 40), "relaunch login failed")
        app2.tapTab("Chat")

        // The group must still be listed, with its history.
        let row = app2.staticTexts[room]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "group disappeared after relaunch")
        row.tap()
        XCTAssertTrue(app2.staticTexts[marker].waitForExistence(timeout: 15), "message history lost after relaunch")
    }
}