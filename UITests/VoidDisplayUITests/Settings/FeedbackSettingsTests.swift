import XCTest

final class FeedbackSettingsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFeedbackSettingsShowsDiagnosticsEntryOnly() throws {
        let app = XCUIApplication()
        configureAppForUITestLaunch(app)
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = SmokeScenario.settingsFeedback.rawValue
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_ISSUE_TYPE"] = "virtualDisplayFailure"
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_HAPPENED"] = "Virtual display does not restore."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_REPRODUCTION"] = "1. Launch the app. 2. Restore displays."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_EXPECTED"] = "The saved display should come back."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_INCLUDE_CONFIGS"] = "1"
        app.launch()
        app.activate()

        assertAllExist(
            app,
            identifiers: [
                "settings_diagnostics_section",
                "settings_diagnostics_intro_text",
                "settings_open_diagnostics_button"
            ],
            timeout: 5
        )

        XCTAssertFalse(app.descendants(matching: .any)["settings_export_support_bundle_button"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["support_bundle_happened_field"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["support_bundle_reproduction_field"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["support_bundle_expected_field"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["support_bundle_include_configs_toggle"].exists)
    }
}
