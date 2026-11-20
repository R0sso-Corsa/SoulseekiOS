import XCTest

/// AD-16 UI acceptance: attach a (seeded) photo in a group, the media bubble
/// renders the actual image from the local sent copy. The picker itself is
/// exercised manually on device; tests use the -UITestSeedMedia hook.
final class MediaUITests: XCTestCase {
    func testSendPhotoRendersInline() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live media UI test is opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetCredentials", "-UITestSeedMedia"]
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

        // Create a group and open it.
        app.tapTab("Chat")
        let room = "SlskMedia" + String(Int.random(in: 1000...9999))
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

        // Attach the seeded photo (bypasses the picker).
        let attach = app.buttons["attachMediaButton"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10), "attach button missing")
        attach.tap()

        // The sent photo renders inline from the local copy.
        if !app.images["mediaImage"].waitForExistence(timeout: 20) {
            print("MEDIA-DIAG: downloading=\(app.otherElements["mediaDownloading"].exists || app.staticTexts["mediaDownloading"].exists) failed=\(app.otherElements["mediaFailed"].exists) rawText=\(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'slsk-media'")).count)")
            print("MEDIA-DIAG: texts=\(app.staticTexts.allElementsBoundByIndex.suffix(12).map { $0.label })")
            let shot = XCUIScreen.main.screenshot()
            let att = XCTAttachment(screenshot: shot)
            att.name = "media-FAILURE"
            att.lifetime = .keepAlways
            add(att)
            XCTFail("sent photo never rendered inline")
        }

        // Visual evidence of the rendered attachment.
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "media-rendered"
        att.lifetime = .keepAlways
        add(att)

        // Leave to clean up.
        app.buttons["roomActionsMenu"].tap()
        let leave = app.buttons["leaveRoomButton"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        leave.tap()
    }
}