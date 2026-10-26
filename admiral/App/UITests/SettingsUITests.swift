import XCTest

/// Opening Settings from the sidebar and moving between panes. Reads only the
/// accessibility tree.
final class SettingsUITests: XCTestCase {
    func testSessionsPaneShowsManagedLaunchFlags() {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-uiTest", "1"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)

        let open = app.buttons["settings-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "Settings sidebar row should exist")
        // The rail itself is the "sheet is open" signal now that Governance (and its seeded
        // hook rows) is gone. On macOS a click on a non-key window may only focus it.
        let rail = app.descendants(matching: .any)["settings-section-Sessions"].firstMatch
        for _ in 0..<4 where !rail.exists {
            app.activate()
            open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            _ = rail.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "settings sheet should be open")
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // The Sessions pane shows the launch-options sections (master toggle first).
        XCTAssertTrue(app.staticTexts["Managed launch flags"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Permission mode"].exists)
    }

    /// The three panes added for shareability: Appearance, Bridge & API, Notifications.
    /// Read-only — asserts each pane renders its controls; no toggles are clicked, so no
    /// persisted state changes even outside isolation.
    func testAppearanceBridgeAndNotificationPanesRender() {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-uiTest", "1"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)

        let open = app.buttons["settings-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "Settings sidebar row should exist")
        let rail = app.descendants(matching: .any)["settings-section-Appearance"].firstMatch
        for _ in 0..<4 where !rail.exists {
            app.activate()
            open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            _ = rail.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "settings sheet should be open")
        XCTAssertFalse(app.descendants(matching: .any)["settings-section-General"].firstMatch.exists,
                       "General is not a Settings section")

        func select(_ section: String) {
            let row = app.descendants(matching: .any)["settings-section-\(section)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(section) rail row should exist")
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }

        select("Appearance")
        XCTAssertTrue(app.staticTexts["Theme"].waitForExistence(timeout: 5))

        select("Bridge & API")
        XCTAssertTrue(app.staticTexts["API server"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["settings-operator-mcp-copy"].firstMatch.exists,
                       "Copy token is not a Settings control")
        XCTAssertFalse(app.buttons["Copy token"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings-api-server-toggle"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings-api-server-port"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Scratch tabs"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings-scratch-auto-close"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings-scratch-by-default"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Bridge socket"].exists)

        select("Notifications")
        XCTAssertTrue(app.staticTexts["Session notifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-notifications-toggle"].firstMatch.exists)
    }
}
