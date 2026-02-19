//
//  FreelyDisplayUITests.swift
//  FreelyDisplayUITests
//
//  Created by Phineas Guo on 2025/10/4.
//

import XCTest

final class HomeSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testHomeNavigationSmoke_baseline() throws {
        let app = launchAppForSmoke(scenario: .baseline)

        assertExists(app, identifier: "home_sidebar")
        assertExists(app, identifier: "sidebar_screen")
        assertExists(app, identifier: "sidebar_virtual_display")
        assertExists(app, identifier: "sidebar_monitor_screen")
        assertExists(app, identifier: "sidebar_screen_sharing")

        assertExists(app, identifier: "detail_screen")
        assertExists(app, identifier: "displays_open_system_settings")

        assertExists(app, identifier: "sidebar_virtual_display").tap()
        assertExists(app, identifier: "detail_virtual_display")
        assertExists(app, identifier: "virtual_display_add_button")
        assertAnyExists(app, identifiers: ["virtual_display_row_card", "virtual_displays_empty_state"])

        assertExists(app, identifier: "sidebar_monitor_screen").tap()
        assertExists(app, identifier: "detail_monitor_screen")

        assertExists(app, identifier: "sidebar_screen_sharing").tap()
        assertExists(app, identifier: "detail_screen_sharing")
    }

    @MainActor
    func testPermissionDeniedSmoke_captureAndShare() throws {
        let app = launchAppForSmoke(scenario: .permissionDenied)

        assertExists(app, identifier: "sidebar_monitor_screen").tap()
        assertExists(app, identifier: "detail_monitor_screen")
        assertExists(app, identifier: "capture_permission_guide")
        assertExists(app, identifier: "capture_open_settings_button")
        assertExists(app, identifier: "capture_request_permission_button")
        assertExists(app, identifier: "capture_refresh_button")

        assertExists(app, identifier: "sidebar_screen_sharing").tap()
        assertExists(app, identifier: "detail_screen_sharing")
        assertExists(app, identifier: "share_permission_guide")
        assertExists(app, identifier: "share_open_settings_button")
        assertExists(app, identifier: "share_request_permission_button")
        assertExists(app, identifier: "share_refresh_button")
    }

    @MainActor
    func testVirtualDisplaySmoke_rebuildingRowShowsProgress() throws {
        let app = launchAppForSmoke(scenario: .virtualDisplayRebuilding)

        assertExists(app, identifier: "sidebar_virtual_display").tap()
        assertExists(app, identifier: "detail_virtual_display")
        assertExists(app, identifier: "virtual_display_rebuild_progress")
    }

    @MainActor
    func testVirtualDisplaySmoke_rebuildFailedRowShowsRetry() throws {
        let app = launchAppForSmoke(scenario: .virtualDisplayRebuildFailed)

        assertExists(app, identifier: "sidebar_virtual_display").tap()
        assertExists(app, identifier: "detail_virtual_display")
        let retryButton = assertExists(app, identifier: "virtual_display_rebuild_retry_button")
        XCTAssertTrue(retryButton.isEnabled)
    }

    @MainActor
    func testVirtualDisplayEditSmoke_directSaveActionsWithoutConfirmationAlert() throws {
        let saveOnlyApp = launchAppForSmoke(scenario: .baseline)
        assertExists(saveOnlyApp, identifier: "sidebar_virtual_display").tap()
        assertExists(saveOnlyApp, identifier: "detail_virtual_display")
        assertExists(saveOnlyApp, identifier: "virtual_display_edit_button").tap()
        let saveOnlyForm = assertExists(saveOnlyApp, identifier: "edit_virtual_display_form")
        assertExists(saveOnlyApp, identifier: "virtual_display_edit_mode_hidpi_toggle").tap()
        let saveOnlyButton = assertExists(saveOnlyApp, identifier: "virtual_display_edit_save_only_button")
        let saveAndRebuildButton = assertExists(saveOnlyApp, identifier: "virtual_display_edit_save_and_rebuild_button")
        XCTAssertTrue(saveAndRebuildButton.isEnabled)
        saveOnlyButton.tap()
        XCTAssertFalse(saveOnlyForm.waitForExistence(timeout: 0.3))
        saveOnlyApp.terminate()

        let saveAndRebuildApp = launchAppForSmoke(scenario: .baseline)
        assertExists(saveAndRebuildApp, identifier: "sidebar_virtual_display").tap()
        assertExists(saveAndRebuildApp, identifier: "detail_virtual_display")
        assertExists(saveAndRebuildApp, identifier: "virtual_display_edit_button").tap()
        let saveAndRebuildForm = assertExists(saveAndRebuildApp, identifier: "edit_virtual_display_form")
        assertExists(saveAndRebuildApp, identifier: "virtual_display_edit_mode_hidpi_toggle").tap()
        assertExists(saveAndRebuildApp, identifier: "virtual_display_edit_save_and_rebuild_button").tap()
        XCTAssertFalse(saveAndRebuildForm.waitForExistence(timeout: 0.3))
    }
}
