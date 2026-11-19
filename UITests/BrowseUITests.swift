import XCTest

/// Opt-in live acceptance: search → tap a result's username → user sheet
/// (stats/status) → browse shares → folder list → files with download buttons.
/// Firewalled peers surface a readable error instead of folders — both prove
/// the flow; the Core loopback test covers the happy path deterministically.
final class BrowseUITests: XCTestCase {
    func testLiveUserBrowse() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live browse test is opt-in")
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
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 40), "login did not complete")

        app.tabBars.buttons["Search"].tap()
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("flac")
        app.buttons["searchButton"].tap()
        XCTAssertTrue(app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90), "no results")
        let done = NSPredicate(format: "label BEGINSWITH 'Done'")
        let doneExp = expectation(for: done, evaluatedWith: app.staticTexts["searchStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [doneExp], timeout: 40), .completed, "search never finished")

        // Open the user sheet from the first result group.
        app.buttons["userButton"].firstMatch.tap()
        let browseButton = app.buttons["browseButton"]
        XCTAssertTrue(browseButton.waitForExistence(timeout: 15), "user sheet missing")

        browseButton.tap()
        let folder = app.descendants(matching: .any)["browseFolder"].firstMatch
        let errorText = app.staticTexts["browseError"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && !folder.exists && !errorText.exists {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(folder.exists || errorText.exists, "browse produced neither folders nor an error")

        if folder.exists {
            folder.tap()
            XCTAssertTrue(app.buttons["downloadButton"].firstMatch.waitForExistence(timeout: 15), "folder files missing")
        }

        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "browse-state"
        att.lifetime = .keepAlways
        add(att)
    }
}