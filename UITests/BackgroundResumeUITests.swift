import XCTest

/// Backgrounding mid-download must not lose the transfer: the app pauses on
/// suspend and auto-resumes on foreground, completing without user action.
/// Opt-in: SLSK_USER/SLSK_PASS.
final class BackgroundResumeUITests: XCTestCase {
    func testBackgroundResumeDownload() throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — background resume UI test is opt-in")
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

        app.tapTab("Search")
        let searchField = app.textFields["searchField"]
        searchField.tap()
        searchField.typeText("mp3")
        app.buttons["searchButton"].tap()
        XCTAssertTrue(app.staticTexts["resultFilename"].firstMatch.waitForExistence(timeout: 90), "no results")
        let done = NSPredicate(format: "label BEGINSWITH 'Done'")
        _ = XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: app.staticTexts["searchStatus"])], timeout: 40)

        // Pick downloads from groups with FREE UPLOAD SLOTS (green badge) —
        // busy users queue for minutes; free-slot peers serve immediately.
        // A badge belongs to the section above the next badge: take the first
        // download button below each badge's y position.
        let badges = app.images.matching(identifier: "freeSlotsBadge")
        let buttons = app.buttons.matching(identifier: "downloadButton")
        var badgeYs: [CGFloat] = []
        for i in 0..<badges.count { badgeYs.append(badges.element(boundBy: i).frame.minY) }
        badgeYs.sort()
        var tapped = 0
        for y in badgeYs {
            // First button below this badge (and above the next, if any).
            let nextY = badgeYs.first(where: { $0 > y + 1 }) ?? .greatestFiniteMagnitude
            var best: (CGFloat, XCUIElement)?
            for i in 0..<buttons.count {
                let b = buttons.element(boundBy: i)
                let by = b.frame.minY
                if by > y && by < nextY && (best == nil || by < best!.0) {
                    best = (by, b)
                }
            }
            if let (_, b) = best {
                b.tap()
                tapped += 1
                Thread.sleep(forTimeInterval: 0.3)
            }
            if tapped >= 6 { break }
        }
        XCTAssertTrue(tapped > 0, "no free-slot candidates found")
        app.tapTab("Transfers")
        XCTAssertTrue(app.staticTexts["transferFilename"].firstMatch.waitForExistence(timeout: 10), "no transfer queued")

        // Background past the ~30s grace period so pauseAll actually fires.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 35)
        app.activate()

        // Deterministic acceptance: resumeAll must re-engage the transfers
        // without user action — within 20s at least one is active again
        // (connecting/queued/downloading) or already completed. A broken
        // resume leaves everything stuck at "Paused".
        let activeLabels: Set<String> = ["Connecting…", "In queue", "Downloading", "Completed", "Queued"]
        let reengaged = { () -> Bool in
            let states = app.staticTexts.matching(identifier: "transferState")
            for i in 0..<states.count {
                let label = states.element(boundBy: i).label
                if activeLabels.contains(label) || label.hasPrefix("In queue #") { return true }
            }
            return false
        }
        var ok = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if reengaged() { ok = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let states = app.staticTexts.matching(identifier: "transferState")
        for i in 0..<states.count {
            print("TRANSFER-STATE[\(i)]: \(states.element(boundBy: i).label)")
        }
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = ok ? "background-resume-PASS" : "background-resume-FAILURE"
        att.lifetime = .keepAlways
        add(att)
        XCTAssertTrue(ok, "transfers were not re-engaged after foreground — resume broken")

        // Best effort: a free-slot peer may finish within the window (byte-exact
        // completion itself is gated by LiveTransferTests + loopback resume tests).
        let completed = app.staticTexts.matching(NSPredicate(format: "label == 'Completed'")).firstMatch
        if completed.waitForExistence(timeout: 120) {
            print("BACKGROUND-RESUME: a download completed after the cycle")
        }
    }
}