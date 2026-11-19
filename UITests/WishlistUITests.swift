import XCTest

/// Opt-in live acceptance: search → save to wishlist → open wishlist →
/// row present → tap it → search re-runs with that query.
final class WishlistUITests: XCTestCase {
    func testLiveWishlistSaveAndRun() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetCredentials"]
        app.launch()

        let userField = app.textFields["usernameField"]
        XCTAssertTrue(userField.waitForExistence(timeout: 15))
        userField.tap()
        userField.typeText(user)
        let passField = app.secureTextFields["passwordField"]
        passField.tap()
        passField.typeText(pass)
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "login did not complete")

        app.tapTab("Search")
        XCTAssertTrue(app.staticTexts["searchStatus"].waitForExistence(timeout: 10), "search screen not presented")
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("flac")
        app.buttons["searchButton"].tap()
        XCTAssertTrue(app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90), "no results")

        // Save the current query, open the wishlist, verify the row.
        // A transient drop may cover the UI with the login overlay; wait it out.
        if app.textFields["usernameField"].exists {
            XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "reconnect did not complete")
            app.tapTab("Search")
        }
        let saveBtn = app.buttons["saveWishButton"]
        if !saveBtn.waitForExistence(timeout: 10) {
            let failShot = XCUIScreen.main.screenshot()
            let failAtt = XCTAttachment(screenshot: failShot)
            failAtt.name = "wishlist-FAILURE"
            failAtt.lifetime = .keepAlways
            add(failAtt)
            XCTFail("saveWishButton missing")
        }
        saveBtn.tap()
        app.buttons["wishlistButton"].tap()
        let row = app.buttons["wishRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "wishlist row missing")
        XCTAssertTrue(row.label.contains("flac"), "row should show the saved query")

        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "wishlist-state"
        att.lifetime = .keepAlways
        add(att)

        // Tap the row → sheet closes and the search re-runs.
        row.tap()
        XCTAssertTrue(app.buttons["searchButton"].waitForExistence(timeout: 10), "sheet did not close")
        XCTAssertEqual(app.textFields["searchField"].value as? String, "flac")
    }
}