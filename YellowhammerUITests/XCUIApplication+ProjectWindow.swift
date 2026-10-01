import XCTest

extension XCUIApplication {
    /// Opens the Project Window from the app menu and waits for its Recalibrate screen.
    ///
    /// The Project Window is temporary: the app launches on the Overview window, and Recalibrate stays in
    /// the Project Window until its replacement ships (roadmap P18.14).
    func openProjectWindow() {
        let item = menuBars.menuItems["Project Window\u{2026}"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "The Project Window menu item is missing")
        item.click()
        XCTAssertTrue(buttons["recalibrate-refresh"].waitForExistence(timeout: 10), "The Project Window did not open")
    }
}
