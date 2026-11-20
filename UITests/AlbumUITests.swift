import XCTest

/// Album support: downloads group by their original Soulseek folder; the
/// album header plays all tracks as a queue with auto-advance; whole albums
/// delete via a two-step confirmation. Seeded real audio + manifest.
final class AlbumUITests: XCTestCase {
    private func launchAndOpenLibrary() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live album UI test is opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetCredentials", "-UITestSeedAlbum"]
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
        return app
    }

    func testAlbumGroupsPlayAllAndAutoAdvances() throws {
        let app = try launchAndOpenLibrary()

        // Album header with both tracks.
        let header = app.staticTexts.matching(NSPredicate(format: "label == 'Test Album'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "album header missing")
        XCTAssertTrue(app.staticTexts["01 First Tone.wav"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["02 Second Tone.wav"].exists)

        // Play-all opens the queue at track 1.
        let playAll = app.buttons["albumPlayButton"].firstMatch
        XCTAssertTrue(playAll.exists, "album play button missing")
        playAll.tap()
        let title = app.staticTexts["previewTrackTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "preview sheet missing")
        XCTAssertEqual(title.label, "01 First Tone.wav")
        let posLabel = app.staticTexts["previewTrackPosition"].label
        XCTAssertTrue(posLabel.contains("1 of 2"), "position label was: '\(posLabel)'")

        // Play → auto-advance to track 2 when the 2s tone ends. Poll the
        // SHEET's title (a bare label match hits the library row behind it).
        app.buttons["previewPlayPause"].tap()
        let titleEl = app.staticTexts["previewTrackTitle"]
        var advanced = false
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if titleEl.label == "02 Second Tone.wav" { advanced = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(advanced, "queue did not auto-advance (title: \(titleEl.label))")
        let pos2 = app.staticTexts["previewTrackPosition"].label
        XCTAssertTrue(pos2.contains("2 of 2"), "position after advance was: '\(pos2)'")

        // Previous returns to track 1.
        app.buttons["previewPrevious"].tap()
        var wentBack = false
        let deadline2 = Date().addingTimeInterval(5)
        while Date() < deadline2 {
            if titleEl.label == "01 First Tone.wav" { wentBack = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(wentBack, "previous track failed (title: \(titleEl.label))")

        app.buttons["previewDoneButton"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10), "did not return to library")
    }

    func testTapTrackTitlePlaysThatTrack() throws {
        let app = try launchAndOpenLibrary()
        let track2 = app.staticTexts["02 Second Tone.wav"]
        XCTAssertTrue(track2.waitForExistence(timeout: 10))
        track2.tap()
        let title = app.staticTexts["previewTrackTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "title tap did not open preview")
        XCTAssertEqual(title.label, "02 Second Tone.wav", "tapping a track must start at that track")
        let pos2 = app.staticTexts["previewTrackPosition"].label
        XCTAssertTrue(pos2.contains("2 of 2"), "position after advance was: '\(pos2)'")
        app.buttons["previewDoneButton"].tap()
    }

    func testDeleteWholeAlbumTwoStep() throws {
        let app = try launchAndOpenLibrary()
        let header = app.staticTexts.matching(NSPredicate(format: "label == 'Test Album'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))

        // Album menu → Delete album → confirmation shows the track count.
        let menu = app.buttons["albumMenu"].firstMatch
        XCTAssertTrue(menu.exists)
        menu.tap()
        let deleteOption = app.buttons["Delete album"]
        XCTAssertTrue(deleteOption.waitForExistence(timeout: 5), "album delete option missing")
        deleteOption.tap()

        let confirm = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Delete 2 tracks'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "album delete confirmation missing")
        // Nothing deleted before confirming.
        XCTAssertTrue(app.staticTexts["01 First Tone.wav"].exists)
        confirm.tap()

        XCTAssertTrue(app.staticTexts["libraryEmpty"].waitForExistence(timeout: 10), "album not deleted")
    }
}