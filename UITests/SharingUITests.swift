import XCTest

/// Opt-in live acceptance: Transfers tab → Sharing sheet shows the seeded
/// share root + counts; Uploads segment renders. (The upload DATA path is
/// gated by UploadEngineTests loopback + LiveUploadTests NAT boundary.)
final class SharingUITests: XCTestCase {
    func testLiveSharingSettings() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetCredentials", "-UITestSeedShare"]
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
        // The system "Save Password?" prompt can appear and eat taps.
        let notNow = app.alerts.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }

        app.tapTab("Transfers")
        XCTAssertTrue(app.buttons["Downloads"].waitForExistence(timeout: 10), "Transfers screen not presented")
        let sharingButton = app.buttons["sharingButton"]
        if !sharingButton.waitForExistence(timeout: 10) {
            let failShot = XCUIScreen.main.screenshot()
            let failAtt = XCTAttachment(screenshot: failShot)
            failAtt.name = "sharing-FAILURE"
            failAtt.lifetime = .keepAlways
            add(failAtt)
            print("HIERARCHY-START\n\(String(app.debugDescription.prefix(6000)))\nHIERARCHY-END")
            XCTFail("Transfers tab missing")
        }
        sharingButton.tap()

        let rootRow = app.staticTexts["shareRootRow"].firstMatch
        if !rootRow.waitForExistence(timeout: 15) {
            app.waitForReconnect(tab: "Transfers")
            sharingButton.tap()
            XCTAssertTrue(rootRow.waitForExistence(timeout: 15), "seeded share root missing")
        }
        XCTAssertEqual(rootRow.label, "SeedShare")
        let count = app.staticTexts["shareFileCount"]
        if !count.waitForExistence(timeout: 5) {
            // Stats section can sit below the fold; List rows only enter the
            // accessibility hierarchy once scrolled into view.
            app.swipeUp()
            if !count.waitForExistence(timeout: 5) {
                app.waitForReconnect(tab: "Transfers")
                sharingButton.tap()
                app.swipeUp()
            }
            XCTAssertTrue(count.waitForExistence(timeout: 10), "share file count missing")
        }
        XCTAssertEqual(count.label, "1")

        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "sharing-state"
        att.lifetime = .keepAlways
        add(att)

        app.buttons["Done"].tap()
        // Uploads segment renders its empty state.
        app.buttons["Uploads"].tap()
        XCTAssertTrue(app.staticTexts["No uploads"].waitForExistence(timeout: 10), "uploads segment missing")
    }
}