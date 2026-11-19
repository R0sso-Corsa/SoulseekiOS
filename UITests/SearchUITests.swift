import XCTest

/// Live search acceptance through the full app path. Opt-in: requires
/// SLSK_USER / SLSK_PASS in the test runner environment (xctestrun injection).
final class SearchUITests: XCTestCase {
    func testLiveSearch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live search UI test is opt-in")
        }

        let app = XCUIApplication()
        app.launchArguments.append("-UITestResetCredentials")
        app.launch()

        // Log in.
        let username = app.textFields["usernameField"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText(user)
        let password = app.secureTextFields["passwordField"]
        password.tap()
        password.typeText(pass)
        app.buttons["connectButton"].tap()
        // Connected state is now a TabView; the tab bar appearing is the signal.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "did not reach connected state")

        // Switch to the Search tab and run a query.
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5), "Search tab missing")
        searchTab.tap()

        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("flac")
        app.buttons["searchButton"].tap()

        // Results must arrive from the live network via the indirect path.
        let firstRow = app.staticTexts["resultFilename"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 60), "no search results rendered")
        XCTAssertTrue(app.staticTexts["searchStatus"].exists)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "search-results"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}