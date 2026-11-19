import XCTest

/// Live acceptance: add a buddy from the user sheet, see them in the Buddies
/// list with a status. Opt-in: SLSK_USER/SLSK_PASS.
final class BuddiesUITests: XCTestCase {
    func testLiveAddBuddy() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — buddies UI test is opt-in")
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

        // Find a live user via search.
        app.tapTab("Search")
        let searchField = app.textFields["searchField"]
        searchField.tap()
        searchField.typeText("flac")
        app.buttons["searchButton"].tap()
        XCTAssertTrue(app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90), "no results")
        let done = NSPredicate(format: "label BEGINSWITH 'Done'")
        _ = XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: app.staticTexts["searchStatus"])], timeout: 40)

        // Open the user sheet, add to buddies, close.
        app.buttons["userButton"].firstMatch.tap()
        let addBuddy = app.buttons["addBuddyFromUserButton"]
        if !addBuddy.waitForExistence(timeout: 8) {
            app.buttons["userButton"].firstMatch.tap()
        }
        XCTAssertTrue(addBuddy.waitForExistence(timeout: 10), "user sheet missing buddy action")
        addBuddy.tap()
        app.buttons["Done"].tap()

        // Chat → + → Buddies: the row must exist.
        app.tapTab("Chat")
        app.selectMenuItem("newChatButton", item: "Buddies")
        let row = app.staticTexts["buddyRow"].firstMatch
        let ok = row.waitForExistence(timeout: 15)
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = ok ? "buddies-PASS" : "buddies-FAILURE"
        att.lifetime = .keepAlways
        add(att)
        XCTAssertTrue(ok, "buddy row missing from Buddies sheet")
    }
}