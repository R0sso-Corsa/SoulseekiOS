import XCTest

/// Library management: seeded download lists with size/storage, swipe-delete
/// removes it. Opt-in: SLSK_USER/SLSK_PASS (login needed to reach the tab).
final class LibraryUITests: XCTestCase {
    func testLibraryListAndDelete() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — library UI test is opt-in")
        }

        let app = XCUIApplication()
        app.launchArguments.append("-UITestResetCredentials")
        app.launchArguments.append("-UITestSeedLibrary")
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

        app.tapTab("Transfers")
        let librarySegment = app.buttons["Library"]
        XCTAssertTrue(librarySegment.waitForExistence(timeout: 10))
        librarySegment.tap()

        let file = app.staticTexts["libraryFile"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "seeded library file missing")
        XCTAssertEqual(file.label, "Seed Track.mp3")
        XCTAssertTrue(app.staticTexts["libraryStorage"].exists, "storage footer missing")

        // Swipe-delete the row (retry — iOS 26 tap quirk).
        var deleted = false
        for _ in 0..<3 {
            file.swipeLeft()
            let delete = app.buttons["libraryDeleteButton"].firstMatch
            if delete.waitForExistence(timeout: 3) {
                delete.tap()
            }
            if app.staticTexts["libraryEmpty"].waitForExistence(timeout: 2) {
                deleted = true
                break
            }
        }
        XCTAssertTrue(deleted, "file not deleted")

        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "library-PASS"
        att.lifetime = .keepAlways
        add(att)
    }

    /// Visible trash button + confirmation deletes the file (the swipe
    /// gesture alone was too hidden).
    func testLibraryDeleteViaButton() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live library UI test is opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetCredentials", "-UITestSeedLibrary"]
        app.launch()
        let username = app.textFields["usernameField"]
        XCTAssertTrue(username.waitForExistence(timeout: 15))
        username.tap()
        username.typeText(user)
        let password = app.secureTextFields["passwordField"]
        password.tap()
        password.typeText(pass)
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "login failed")

        app.tapTab("Transfers")
        let librarySegment = app.buttons["Library"]
        XCTAssertTrue(librarySegment.waitForExistence(timeout: 10))
        librarySegment.tap()
        let file = app.staticTexts["libraryFile"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "seeded library file missing")

        let trash = app.buttons["libraryDeleteRowButton"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "visible delete button missing")
        trash.tap()

        // Confirmation sheet → Delete (retry — iOS 26 sheet taps can no-op).
        var deleted = false
        for _ in 0..<3 {
            let confirm = app.buttons["Delete"].firstMatch
            if confirm.waitForExistence(timeout: 5) {
                confirm.tap()
            }
            if app.staticTexts["libraryEmpty"].waitForExistence(timeout: 3) {
                deleted = true
                break
            }
            if !app.buttons["Cancel"].exists {
                // Dialog dismissed but list not empty yet — give it a moment.
                if app.staticTexts["libraryEmpty"].waitForExistence(timeout: 3) {
                    deleted = true
                    break
                }
            }
        }
        if !deleted {
            print("DELETE-DIAG: cancel=\(app.buttons["Cancel"].exists) file=\(app.staticTexts["libraryFile"].firstMatch.exists) empty=\(app.staticTexts["libraryEmpty"].exists)")
            XCTFail("file not deleted via button")
        }
    }
}