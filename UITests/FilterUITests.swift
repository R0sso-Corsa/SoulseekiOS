import XCTest

/// Live acceptance for the extended search filters: custom minimum bitrate
/// (beyond the 320 preset) and minimum bit depth. Opt-in: SLSK_USER/SLSK_PASS.
final class FilterUITests: XCTestCase {
    func testLiveCustomBitrateAndBitDepth() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live filter UI test is opt-in")
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
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 30), "login did not complete")
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }

        app.tapTab("Search")
        XCTAssertTrue(app.staticTexts["searchStatus"].waitForExistence(timeout: 10))
        let searchField = app.textFields["searchField"]
        searchField.tap()
        searchField.typeText("flac")
        app.buttons["searchButton"].tap()
        XCTAssertTrue(app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90), "no search results")
        let initialShot = XCUIScreen.main.screenshot()
        let initialAtt = XCTAttachment(screenshot: initialShot)
        initialAtt.name = "filters-INITIAL"
        initialAtt.lifetime = .keepAlways
        add(initialAtt)

        // --- Bit depth filter: 24-bit+ ---
        XCTAssertTrue(app.buttons["Depth"].waitForExistence(timeout: 5), "Depth chip missing")
        app.openMenu("Depth", item: "24-bit+")
        let depthOption = app.buttons["24-bit+"]
        XCTAssertTrue(depthOption.waitForExistence(timeout: 5), "24-bit+ menu item missing")
        depthOption.tap()
        let depthText = app.staticTexts["fileBitDepth"].firstMatch
        XCTAssertTrue(depthText.waitForExistence(timeout: 20), "no files with bit depth shown after 24-bit+ filter")
        XCTAssertTrue(["24-bit", "32-bit"].contains(depthText.label),
                      "filtered row shows unexpected bit depth: \(depthText.label)")
        // Reset depth so the bitrate step sees results again (chip now reads "24+").
        app.openMenu("24+", item: "Any depth")
        app.buttons["Any depth"].tap()

        // --- Custom minimum bitrate: 1000 kbps (beyond the 320 preset) ---
        XCTAssertTrue(app.buttons["Bitrate"].waitForExistence(timeout: 5), "Bitrate chip missing")
        app.openMenu("Bitrate", item: "Custom…")
        let customItem = app.buttons["Custom…"]
        XCTAssertTrue(customItem.waitForExistence(timeout: 5), "Custom… menu item missing")
        customItem.tap()
        let alert = app.alerts["Custom min bitrate"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "custom bitrate alert missing")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("1000")
        alert.buttons["Apply"].tap()
        let customChip = app.buttons["1000+"]
        XCTAssertTrue(customChip.waitForExistence(timeout: 10), "chip did not update to custom value 1000+")

        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "filters-PASS"
        att.lifetime = .keepAlways
        add(att)
    }
}