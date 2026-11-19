import XCTest

/// Settings persistence: Wi-Fi-only toggle + speed limit survive closing the
/// sheet. Deterministic (no network needed beyond login). Opt-in credentials.
final class SettingsUITests: XCTestCase {
    func testSettingsPersist() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — settings UI test is opt-in")
        }

        let app = XCUIApplication()
        app.launchArguments.append("-UITestResetCredentials")
        app.launchArguments.append("-UITestResetSettings")
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

        app.tapTab("Search")
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        let toggle = app.switches["wiFiOnlyToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "settings sheet missing")
        for _ in 0..<3 {
            if toggle.value as? String == "1" { break }
            // The AX switch spans the whole row; the real knob sits at the
            // right edge — tap there.
            let f = toggle.frame
            app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: f.maxX - 30, dy: f.midY)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(toggle.value as? String, "1", "toggle did not turn on")
        let limit = app.textFields["speedLimitField"]
        limit.tap()
        limit.typeText("500")
        app.buttons["Done"].tap()

        // Reopen: both values must persist.
        gear.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "Wi-Fi-only toggle did not persist")
        XCTAssertEqual(limit.value as? String, "500", "speed limit did not persist")
        app.buttons["Done"].tap()
    }
}