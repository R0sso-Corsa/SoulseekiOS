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
}