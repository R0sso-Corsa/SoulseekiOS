import XCTest

/// Live acceptance: "Search this user" from the user sheet sends a scoped
/// UserSearch and renders that user's results with a scope chip.
/// Opt-in: SLSK_USER/SLSK_PASS.
final class ScopedSearchUITests: XCTestCase {
    func testLiveUserScopedSearch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — scoped search UI test is opt-in")
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

        app.tapTab("Search")
        let searchField = app.textFields["searchField"]
        searchField.tap()
        searchField.typeText("flac")
        app.buttons["searchButton"].tap()
        XCTAssertTrue(app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90), "no global results")
        let done = NSPredicate(format: "label BEGINSWITH 'Done'")
        _ = XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: app.staticTexts["searchStatus"])], timeout: 40)

        // Open the first user's sheet and search their shares.
        app.buttons["userButton"].firstMatch.tap()
        let searchUser = app.buttons["searchUserButton"]
        if !searchUser.waitForExistence(timeout: 8) {
            // iOS 26 tap quirk: retry opening the sheet.
            app.buttons["userButton"].firstMatch.tap()
        }
        XCTAssertTrue(searchUser.waitForExistence(timeout: 10), "user sheet missing search action")
        searchUser.tap()

        // Back on Search with a scope chip; scoped results must arrive.
        let chip = app.buttons["scopeChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "scope chip missing")
        XCTAssertTrue(chip.label.hasPrefix("User:"), "unexpected scope chip: \(chip.label)")
        let gotScoped = app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 60)
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = gotScoped ? "scoped-search-PASS" : "scoped-search-FAILURE"
        att.lifetime = .keepAlways
        add(att)
        XCTAssertTrue(gotScoped, "scoped user search returned no results")
    }
}