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
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 30), "did not reach connected state")

        // Switch to the Search tab and run a query.
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5), "Search tab missing")
        searchTab.tap()
        // Confirm the search screen is fully presented before interacting.
        XCTAssertTrue(app.staticTexts["searchStatus"].waitForExistence(timeout: 10), "search screen not presented")

        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("flac")
        app.buttons["searchButton"].tap()

        // Results must arrive from the live network via the indirect path.
        let firstRow = app.staticTexts["resultFilename"].firstMatch
        let appeared = firstRow.waitForExistence(timeout: 90)
        // Capture state regardless, so failures are diagnosable.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = appeared ? "search-results" : "search-FAILURE"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(appeared, "no search results rendered")
        XCTAssertTrue(app.staticTexts["searchStatus"].exists)

        // Let the search finish so the results list is stable before tapping.
        let done = NSPredicate(format: "label BEGINSWITH 'Done'")
        let doneExpectation = expectation(for: done, evaluatedWith: app.staticTexts["searchStatus"])
        let doneResult = XCTWaiter.wait(for: [doneExpectation], timeout: 40)
        if doneResult != .completed {
            let failShot = XCUIScreen.main.screenshot()
            let failAtt = XCTAttachment(screenshot: failShot)
            failAtt.name = "done-wait-FAILURE"
            failAtt.lifetime = .keepAlways
            add(failAtt)
            print("HIERARCHY-START\n\(String(app.debugDescription.prefix(4000)))\nHIERARCHY-END")
        }

        // Enqueue a download from the first result; verify the Transfers tab.
        app.buttons["downloadButton"].firstMatch.tap()
        let transfersTab = app.tabBars.buttons["Transfers"]
        XCTAssertTrue(transfersTab.waitForExistence(timeout: 5), "Transfers tab missing")
        transfersTab.tap()
        XCTAssertTrue(app.staticTexts["transferFilename"].firstMatch.waitForExistence(timeout: 10), "transfer did not appear")

        let transfersShot = XCUIScreen.main.screenshot()
        let transfersAttachment = XCTAttachment(screenshot: transfersShot)
        transfersAttachment.name = "transfers-state"
        transfersAttachment.lifetime = .keepAlways
        add(transfersAttachment)
    }
}