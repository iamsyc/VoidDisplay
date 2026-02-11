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
        assertExists(app, identifier: "monitoring_add_button")

        assertExists(app, identifier: "sidebar_screen_sharing").tap()
        assertExists(app, identifier: "detail_screen_sharing")
    }

    @MainActor
    func testPermissionDeniedSmoke_captureAndShare() throws {
        let app = launchAppForSmoke(scenario: .permissionDenied)

        assertExists(app, identifier: "sidebar_monitor_screen").tap()
        assertExists(app, identifier: "detail_monitor_screen")
        assertExists(app, identifier: "monitoring_add_button").tap()

        assertExists(app, identifier: "capture_choose_root")
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
}
