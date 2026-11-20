import XCTest

/// Music preview acceptance: a real audio file plays and gets the "file OK"
/// verdict; a corrupt file surfaces an error. Seeded files, live login.
final class PreviewUITests: XCTestCase {
    private func launchAndOpenLibrary() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live preview UI test is opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetCredentials", "-UITestSeedLibrary", "-UITestSeedPreview"]
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
        app.tapTab("Transfers")
        let librarySegment = app.buttons["Library"]
        XCTAssertTrue(librarySegment.waitForExistence(timeout: 10))
        librarySegment.tap()
        XCTAssertTrue(app.staticTexts["libraryFile"].firstMatch.waitForExistence(timeout: 10), "library empty")
        return app
    }

    /// Tap the preview button on the row containing `name` (row buttons share
    /// one identifier — match by vertical position).
    private func openPreview(_ app: XCUIApplication, for name: String) {
        let label = app.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10), "\(name) not listed")
        let y = label.frame.midY
        let buttons = app.buttons.matching(identifier: "libraryPreviewButton").allElementsBoundByIndex
        let rowButton = buttons.min(by: { abs($0.frame.midY - y) < abs($1.frame.midY - y) })
        XCTAssertNotNil(rowButton, "no preview button near \(name)")
        rowButton?.tap()
    }

    func testPreviewPlaysValidFile() throws {
        let app = try launchAndOpenLibrary()
        openPreview(app, for: "Preview Tone.wav")

        let playPause = app.buttons["previewPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 15), "preview controls never appeared")
        XCTAssertTrue(app.sliders["previewSlider"].exists, "seek slider missing")
        playPause.tap()
        // Playback advancing → the file decodes cleanly.
        XCTAssertTrue(app.otherElements["previewVerified"].waitForExistence(timeout: 15)
                      || app.staticTexts["previewVerified"].waitForExistence(timeout: 5),
                      "valid file never reached the verified state")
        // Pause works.
        playPause.tap()
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "preview-verified"
        att.lifetime = .keepAlways
        add(att)
        app.buttons["previewDoneButton"].tap()
        XCTAssertTrue(app.staticTexts["libraryFile"].firstMatch.waitForExistence(timeout: 10), "did not return to library")
    }

    func testPreviewFlagsCorruptFile() throws {
        let app = try launchAndOpenLibrary()
        // "Seed Track.mp3" is deterministic garbage bytes — not real audio.
        openPreview(app, for: "Seed Track.mp3")
        let error = app.otherElements["previewError"].firstMatch
        let errorText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'corrupted'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 20) || errorText.waitForExistence(timeout: 5),
                      "corrupt file produced no error verdict")
        app.buttons["previewDoneButton"].tap()
    }
}