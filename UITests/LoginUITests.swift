import XCTest

final class LoginUITests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestResetCredentials")
        app.launch()
        return app
    }

    /// Deterministic: no network. Connect stays disabled until both fields are filled.
    func testLoginScreenValidation() {
        let app = launchApp()
        let username = app.textFields["usernameField"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        let connect = app.buttons["connectButton"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled)

        username.tap()
        username.typeText("someone")
        XCTAssertFalse(connect.isEnabled, "password still empty")

        let password = app.secureTextFields["passwordField"]
        password.tap()
        password.typeText("secret")
        XCTAssertTrue(connect.isEnabled)
    }

    /// Opt-in live acceptance: real server through the full app path.
    /// Requires SLSK_USER / SLSK_PASS in the *test runner* environment.
    func testLiveLogin() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live UI test is opt-in")
        }

        let app = launchApp()
        let username = app.textFields["usernameField"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText(user)
        let password = app.secureTextFields["passwordField"]
        password.tap()
        password.typeText(pass)
        app.buttons["connectButton"].tap()

        // Connected state is a TabView; check the Status tab for details.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "login did not reach Connected")
        let statusTab = app.tabBars.buttons["Status"]
        XCTAssertTrue(statusTab.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.5) // let the tab transition settle
        statusTab.tap()
        let connected = app.staticTexts["connectedLabel"]
        if !connected.waitForExistence(timeout: 3) {
            statusTab.tap() // retry once if the first tap landed mid-transition
        }
        XCTAssertTrue(connected.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["publicIPValue"].exists)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "connected-state"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["disconnectButton"].tap()
        XCTAssertTrue(app.textFields["usernameField"].waitForExistence(timeout: 10), "disconnect should return to login")
    }
}