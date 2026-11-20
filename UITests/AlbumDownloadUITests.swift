import XCTest

/// Album download UI flow: one tap on a search group / browsed folder queues
/// every track (notice + Transfers rows). Byte-exact album completion over
/// the live network is gated by LiveAlbumDownloadTests (parallel candidates,
/// size-filtered) — the UI cannot filter peer health, so this test verifies
/// the queueing flow only.
final class AlbumDownloadUITests: XCTestCase {
    private func loginAndSearch(_ app: XCUIApplication) throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live album download test is opt-in")
        }
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
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "login failed")
        app.tapTab("Search") // iOS 26: explicit tab tap before typing (focus synthesis)
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("mp3")
        app.buttons["searchButton"].tap()
        XCTAssertTrue(app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90), "no search results")
    }

    private func dismissQueuedAlert(_ app: XCUIApplication) {
        let alert = app.alerts["Album queued"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "queued notice missing")
        for _ in 0..<3 {
            alert.buttons["OK"].tap()
            if alert.waitForNonExistence(timeout: 3) { break }
        }
    }

    /// Transfers tab shows queued rows for the album.
    private func verifyQueued(_ app: XCUIApplication) {
        for _ in 0..<3 {
            app.tapTab("Transfers")
            if app.tabBars.buttons["Transfers"].isSelected { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(app.staticTexts["transferFilename"].firstMatch.waitForExistence(timeout: 30),
                      "no transfers queued after album tap")
    }

    func testDownloadAlbumFromSearchGroup() throws {
        let app = XCUIApplication()
        try loginAndSearch(app)
        let dl = app.buttons["groupDownloadButton"].firstMatch
        XCTAssertTrue(dl.waitForExistence(timeout: 10), "group download button missing")
        dl.tap()
        dismissQueuedAlert(app)
        verifyQueued(app)
    }

    func testDownloadFolderFromBrowse() throws {
        let app = XCUIApplication()
        try loginAndSearch(app)
        // Browse can fail for individual peers (both firewalled) — try three.
        var loaded = false
        for attempt in 0..<3 {
            let users = app.buttons.matching(identifier: "userButton").allElementsBoundByIndex
            guard !users.isEmpty else { break }
            users[min(attempt, users.count - 1)].tap()
            let browseButton = app.buttons["browseButton"]
            XCTAssertTrue(browseButton.waitForExistence(timeout: 15), "user sheet missing")
            browseButton.tap()
            let folder = app.descendants(matching: .any)["browseFolder"].firstMatch
            if folder.waitForExistence(timeout: 45) { loaded = true; break }
            app.buttons["Done"].tap()
            _ = app.buttons["userButton"].firstMatch.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(loaded, "browse never loaded for any candidate")
        let dl = app.buttons["folderDownloadButton"].firstMatch
        XCTAssertTrue(dl.waitForExistence(timeout: 5), "folder download button missing")
        dl.tap()
        dismissQueuedAlert(app)
        // Pop to the sheet root and close it — the tab bar is unreachable
        // while the browse sheet is presented.
        for _ in 0..<2 {
            let back = app.navigationBars.buttons.firstMatch
            if back.exists { back.tap() }
        }
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        verifyQueued(app)
    }
}