import XCTest

extension XCUIApplication {
    /// Opens the Project Window from the app menu and waits for its Configuration tab.
    ///
    /// The Project Window is temporary: the app launches on the Overview window, and the legacy
    /// screens stay in the Project Window until their replacements ship (roadmap P18.7–P18.14).
    func openProjectWindow() {
        let item = menuBars.menuItems["Project Window\u{2026}"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "The Project Window menu item is missing")
        item.click()
        XCTAssertTrue(tabs["Configuration"].waitForExistence(timeout: 10), "The Project Window did not open")
    }
}
