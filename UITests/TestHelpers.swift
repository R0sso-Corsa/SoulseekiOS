import XCTest

/// iOS 26 beta quirk: XCUIElement.tap() on floating-glass tab bar buttons
/// sometimes doesn't register; a coordinate tap at the frame center does.
extension XCUIApplication {
    func tapTab(_ label: String) {
        let tab = tabBars.buttons[label]
        guard tab.waitForExistence(timeout: 10) else { return }
        tab.tap()
        Thread.sleep(forTimeInterval: 0.5)
        if !tab.isSelected {
            let f = tab.frame
            coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Tap a chip/menu button, retrying until the expected menu item appears
    /// (the same tap quirk affects menu labels).
    func openMenu(_ chipLabel: String, item: String) {
        let chip = buttons[chipLabel]
        for _ in 0..<3 {
            guard chip.waitForExistence(timeout: 5) else { return }
            chip.tap()
            if buttons[item].waitForExistence(timeout: 3) { return }
        }
    }

    /// Wait out a transient disconnect (login overlay), then return to a tab.
    func waitForReconnect(tab: String) {
        if textFields["usernameField"].exists {
            _ = textFields["usernameField"].waitForNonExistence(timeout: 40)
            tapTab(tab)
        }
    }
}