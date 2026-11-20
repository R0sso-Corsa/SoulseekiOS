import XCTest

/// Live private-room UI acceptance: create private group → invite the probe
/// account → promote to operator → leave. Plus group-browser search filtering.
final class PrivateRoomUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchAndLogin() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SLSK_USER"], let pass = env["SLSK_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("SLSK_USER/SLSK_PASS not set — live private-room UI test is opt-in")
        }
        let app = XCUIApplication()
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
        XCTAssertTrue(app.textFields["usernameField"].waitForNonExistence(timeout: 40), "login did not complete")
        return app
    }

    @MainActor
    func testCreatePrivateGroupInviteAndManage() throws {
        let app = try launchAndLogin()
        app.tapTab("Chat")

        let room = "SlskUI" + String(Int.random(in: 1000...9999))
        let plus = app.buttons["newChatButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "chat tab missing")
        plus.tap()
        let newRoomItem = app.buttons["Create private group"]
        XCTAssertTrue(newRoomItem.waitForExistence(timeout: 10), "menu did not open")
        newRoomItem.tap()
        let alert = app.alerts["Create a private group"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "private room alert missing")
        let nameField = alert.textFields.firstMatch
        nameField.tap()
        nameField.typeText(room)
        alert.buttons.matching(identifier: "Create").firstMatch.tap()

        // Private room → Manage is a dedicated toolbar button (never overflowed).
        let manage = app.buttons["manageRoomButton"]
        XCTAssertTrue(manage.waitForExistence(timeout: 25), "Manage button missing — room not private?")
        manage.tap()

        // Invite the probe account.
        let inviteField = app.textFields["inviteNameField"]
        XCTAssertTrue(inviteField.waitForExistence(timeout: 10), "invite field missing")
        inviteField.tap()
        inviteField.typeText("slsk_spike_b36c824")
        app.buttons["inviteButton"].tap()

        // Server echoes AddRoomMember → member row appears.
        let memberRow = app.staticTexts.matching(NSPredicate(format: "label == 'slsk_spike_b36c824'")).firstMatch
        if !memberRow.waitForExistence(timeout: 20) {
            print("MEMBER-DIAG: texts=\(app.staticTexts.allElementsBoundByIndex.prefix(30).map { $0.label })")
            XCTFail("invited member never appeared")
        }

        // Promote to operator via the member menu.
        let menu = app.buttons["memberMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "member menu missing")
        menu.tap()
        let makeOp = app.buttons["Make operator"]
        XCTAssertTrue(makeOp.waitForExistence(timeout: 5), "operator menu item missing")
        makeOp.tap()
        XCTAssertTrue(app.staticTexts["op"].waitForExistence(timeout: 20), "operator badge never appeared")

        // Leave the private group (CancelRoomMembership).
        app.buttons["leavePrivateButton"].tap()
        XCTAssertTrue(app.buttons["newChatButton"].waitForExistence(timeout: 15), "did not return to chat list")
    }

    /// Creating a "private" group with an existing PUBLIC group's name must
    /// show a warning, not silently open a public room without Manage.
    @MainActor
    func testPrivateCreateCollisionShowsWarning() throws {
        let app = try launchAndLogin()
        app.tapTab("Chat")
        let room = "SlskCol" + String(Int.random(in: 1000...9999))

        // 1. Create the name as a PUBLIC group.
        let plus = app.buttons["newChatButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        app.buttons["Create / join group"].tap()
        let pubAlert = app.alerts["Create or join a group"]
        XCTAssertTrue(pubAlert.waitForExistence(timeout: 10))
        pubAlert.textFields.firstMatch.tap()
        pubAlert.textFields.firstMatch.typeText(room)
        pubAlert.buttons.matching(identifier: "Join / Create").firstMatch.tap()
        XCTAssertTrue(app.buttons["roomActionsMenu"].waitForExistence(timeout: 25), "public room view missing")

        // Leave it (⋯ → Leave).
        app.buttons["roomActionsMenu"].tap()
        let leave = app.buttons["leaveRoomButton"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        leave.tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "did not return to chat list")

        // 2. "Create private" with the SAME name → warning in the room.
        plus.tap()
        app.buttons["Create private group"].tap()
        let privAlert = app.alerts["Create a private group"]
        XCTAssertTrue(privAlert.waitForExistence(timeout: 10))
        privAlert.textFields.firstMatch.tap()
        privAlert.textFields.firstMatch.typeText(room)
        privAlert.buttons.matching(identifier: "Create").firstMatch.tap()

        let warning = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'PUBLIC'")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 25), "collision warning never appeared")
        XCTAssertFalse(app.buttons["manageRoomButton"].exists, "public collision room must not show Manage")
    }

    @MainActor
    func testRoomSearchFilters() throws {
        let app = try launchAndLogin()
        app.tapTab("Chat")

        let plus = app.buttons["newChatButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        let browse = app.buttons["Browse groups"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "menu did not open")
        browse.tap()

        // "Your groups" may push public rows below the fold — scroll first.
        app.swipeUp()
        app.swipeUp()
        let firstRow = app.buttons["roomRow"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 25), "room list never loaded")
        let before = app.buttons.matching(identifier: "roomRow").count
        XCTAssertGreaterThan(before, 10, "expected many public rooms")

        // Scroll back to the top — offscreen elements are absent from the
        // AX hierarchy, so the search field must be visible before tapping.
        app.swipeDown()
        app.swipeDown()
        let search = app.textFields["roomSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "search field not visible at top")
        search.tap()
        search.typeText("zzzznope")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(app.buttons.matching(identifier: "roomRow").count, 0, "search did not filter")

        // Clear via select-all + delete → rows return.
        search.tap()
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) {
            selectAll.tap()
            app.typeText(XCUIKeyboardKey.delete.rawValue)
        } else {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        }
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "rows did not return after clearing search")
    }
}