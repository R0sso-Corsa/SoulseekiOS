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
        let done = NSPredicate(format: "label BEGINSWITH 'Done'")
        let chip = app.buttons["scopeChip"]
        var gotScoped = false

        // Some peers ignore UserSearch or go offline between replies — try
        // up to three different users from the global results.
        for attempt in 0..<3 {
            if chip.exists { chip.tap() }  // clear any previous scope
            app.buttons["searchButton"].tap()
            guard app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90) else { continue }
            _ = XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: app.staticTexts["searchStatus"])], timeout: 40)

            let userButton = app.buttons.matching(identifier: "userButton").element(boundBy: attempt)
            guard userButton.waitForExistence(timeout: 5) else { continue }
            userButton.tap()
            let searchUser = app.buttons["searchUserButton"]
            if !searchUser.waitForExistence(timeout: 8) {
                userButton.tap()
            }
            guard searchUser.waitForExistence(timeout: 10) else { continue }
            searchUser.tap()

            XCTAssertTrue(chip.waitForExistence(timeout: 10), "scope chip missing")
            XCTAssertTrue(chip.label.hasPrefix("User:"), "unexpected scope chip: \(chip.label)")
            if app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 40) {
                gotScoped = true
                break
            }
        }
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = gotScoped ? "scoped-search-PASS" : "scoped-search-FAILURE"
        att.lifetime = .keepAlways
        add(att)
        XCTAssertTrue(gotScoped, "scoped user search returned no results from any of 3 users")
    }
}