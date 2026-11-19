import XCTest

/// Closing and reopening the app must NOT sign the user out: saved Keychain
/// credentials auto-connect on launch. Opt-in: SLSK_USER/SLSK_PASS.
final class AutoLoginUITests: XCTestCase {
    func testAutoLoginAfterRelaunch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — auto-login UI test is opt-in")
        }

        // First launch: clean slate, log in (saves credentials to Keychain).
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
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "first login failed")
        app.terminate()

        // Second launch: no reset argument — the app must restore the session
        // WITHOUT showing the login form, and reach connected on its own.
        let app2 = XCUIApplication()
        app2.launch()
        XCTAssertFalse(app2.textFields["usernameField"].exists,
                       "login screen flashed on relaunch — session should restore in place")
        app2.tapTab("Status")
        XCTAssertTrue(app2.staticTexts["connectedLabel"].waitForExistence(timeout: 40),
                      "session did not auto-restore to connected")
    }
}