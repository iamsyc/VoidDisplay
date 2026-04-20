import XCTest

final class FeedbackSettingsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFeedbackSettingsExportFlow() throws {
        let app = XCUIApplication()
        configureAppForUITestLaunch(app)
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = SmokeScenario.settingsFeedback.rawValue
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_HAPPENED"] = "Screen stays black after launch."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_REPRODUCTION"] = "1. Launch the app. 2. Open settings. 3. Start sharing."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_EXPECTED"] = "The captured display should appear."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_INCLUDE_CONFIGS"] = "1"
        app.launch()
        app.activate()

        assertAllExist(
            app,
            identifiers: [
                "settings_support_section",
                "settings_open_support_center_button",
                "settings_export_support_bundle_button"
            ],
            timeout: 5
        )

        XCTAssertFalse(app.descendants(matching: .any)["feedback_happened_field"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["feedback_reproduction_field"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["feedback_expected_field"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["feedback_include_configs_toggle"].exists)

        tapIdentifier(app, identifier: "settings_export_support_bundle_button", timeout: 2)

        XCTAssertTrue(
            waitForIdentifierByPolling(
                app,
                identifier: "settings_support_export_completed",
                timeout: 8,
                activateBeforePolling: true
            )
        )

        let pathLabel = assertExists(
            app,
            identifier: "settings_support_latest_bundle_path",
            timeout: 2
        )
        let displayedPath = (pathLabel.value as? String) ?? pathLabel.label
        XCTAssertFalse(displayedPath.isEmpty)
    }
}
