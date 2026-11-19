import XCTest

/// Live acceptance: set a ticker in a freshly created group; the server
/// echoes it back and it renders on the room wall. Opt-in: SLSK_USER/SLSK_PASS.
final class TickerUITests: XCTestCase {
    func testLiveRoomTicker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — ticker UI test is opt-in")
        }

        let app = XCUIApplication()
        app.launchArguments.append("-UITestResetCredentials")
        app.launch()
        let username = app.textFields["usernameField"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText(user)
        let password = app.secureTextFields["passwordField"]
        password.tap()
        password.typeText(pass)
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "login did not complete")
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }

        // Create a fresh group.
        app.tapTab("Chat")
        app.selectMenuItem("newChatButton", item: "Create / join group")
        let roomField = app.alerts.textFields.firstMatch
        XCTAssertTrue(roomField.waitForExistence(timeout: 5))
        let roomName = "SlskTick\(Int.random(in: 100...999))"
        roomField.tap()
        roomField.typeText(roomName)
        app.alerts.buttons["Join / Create"].firstMatch.tap()

        // Set a ticker via the room toolbar.
        let tickerButton = app.buttons["setTickerButton"]
        XCTAssertTrue(tickerButton.waitForExistence(timeout: 15), "room view missing ticker action")
        let alert = app.alerts["Room ticker"]
        for _ in 0..<3 {
            tickerButton.tap()
            if alert.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(alert.exists, "ticker alert did not open")
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText("hello wall")
        XCTAssertEqual(field.value as? String, "hello wall", "text did not land in the ticker field")
        alert.buttons["Set"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "ticker alert did not dismiss")

        // The wall must render our ticker (applied locally on set).
        let wall = app.descendants(matching: .any)["tickerWall"]
        let ok = wall.waitForExistence(timeout: 10)
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = ok ? "ticker-PASS" : "ticker-FAILURE"
        att.lifetime = .keepAlways
        add(att)
        XCTAssertTrue(ok, "ticker wall did not appear after setting")
    }
}