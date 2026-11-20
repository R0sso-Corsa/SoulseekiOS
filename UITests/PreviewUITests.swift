import XCTest

/// Music preview acceptance: a real audio file plays and gets the "file OK"
/// verdict; a corrupt file surfaces an error. Seeded files, live login.
final class PreviewUITests: XCTestCase {
    private func launchAndOpenLibrary(extraSeeds: [String] = ["-UITestSeedLibrary", "-UITestSeedPreview"]) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live preview UI test is opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetCredentials"] + extraSeeds
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

    /// Tap the song TITLE to open its preview (album queue context).
    private func openPreview(_ app: XCUIApplication, for name: String) {
        let label = app.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10), "\(name) not listed")
        label.tap()
    }

    func testPreviewPlaysValidFile() throws {
        // Only the valid tone — a corrupt file in the queue would be
        // auto-advanced into and replace the controls with an error.
        let app = try launchAndOpenLibrary(extraSeeds: ["-UITestSeedPreview"])
        openPreview(app, for: "Preview Tone.wav")

        let playPause = app.buttons["previewPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 15), "preview controls never appeared")
        XCTAssertTrue(app.sliders["previewSlider"].exists, "seek slider missing")
        Thread.sleep(forTimeInterval: 0.8) // let the sheet settle before tapping
        var verified = false
        for _ in 0..<3 {
            if !playPause.exists {
                openPreview(app, for: "Preview Tone.wav")
                _ = playPause.waitForExistence(timeout: 10)
                Thread.sleep(forTimeInterval: 0.8)
            }
            playPause.tap()
            if app.otherElements["previewVerified"].waitForExistence(timeout: 6)
                || app.staticTexts["previewVerified"].waitForExistence(timeout: 2) {
                verified = true
                break
            }
        }
        if !verified {
            print("PREVIEW-DIAG: sheet=\(playPause.exists) slider=\(app.sliders["previewSlider"].exists) title=\(app.staticTexts["previewTrackTitle"].label)")
        }
        XCTAssertTrue(verified, "valid file never reached the verified state")
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