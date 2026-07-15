import XCTest

final class HomeSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeNavigationSmoke_baseline() throws {
        let app = launchAppForSmoke()

        assertAllExist(
            app,
            identifiers: [
                "sidebar_home",
                "sidebar_diagnostics",
                "detail_home",
                "home_virtual_display_surface",
                "home_summary_status_strip",
                "home_sharing_settings_popover_button",
                "home_virtual_display_card"
            ],
            timeout: 6
        )

        XCTAssertFalse(app.descendants(matching: .any)["sidebar_displays"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_virtual_display"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_screen_preview"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_screen_sharing"].exists)

        tapIdentifier(app, identifier: "sidebar_diagnostics")
        assertAllExist(app, identifiers: ["detail_diagnostics"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_home")
        assertAllExist(app, identifiers: ["detail_home", "home_virtual_display_card"], timeout: 1.5)
    }

    @MainActor
    func testVirtualDisplayCardSurfaceSmoke_baseline() throws {
        let app = launchAppForSmoke()

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "home_virtual_display_surface",
                "home_summary_status_strip",
                "home_sharing_settings_popover_button",
                "home_virtual_display_card_grid",
                "home_virtual_display_card",
                "home_card_status_grid",
                "virtual_display_toggle_button",
                "home_virtual_display_preview_button",
                "home_virtual_display_web_view_button",
                "virtual_display_edit_button",
                "home_virtual_display_more_button",
                "home_add_virtual_display_button"
            ],
            timeout: 6
        )

        tapIdentifier(app, identifier: "home_sharing_settings_popover_button")
        assertAllExist(
            app,
            identifiers: [
                "home_sharing_settings_panel",
                "home_sharing_performance_picker",
                "home_sharing_port_input"
            ],
            timeout: 2
        )
    }

    @MainActor
    func testVirtualDisplayCardSurfaceSmoke_compactSkin() throws {
        let app = launchAppForSmoke(skinID: "compact")

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "home_virtual_display_surface",
                "home_summary_panel",
                "home_virtual_display_card_grid",
                "home_virtual_display_card",
                "home_card_status_grid",
                "virtual_display_toggle_button",
                "home_virtual_display_preview_button",
                "home_virtual_display_web_view_button",
                "virtual_display_edit_button",
                "home_virtual_display_more_button"
            ],
            timeout: 6
        )
    }

    @MainActor
    func testCompactCardActionsRemainVisibleAtNarrowWindowSize() throws {
        let app = launchAppForSmoke(skinID: "compact", windowSize: (760, 640))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))

        for identifier in [
            "virtual_display_toggle_button",
            "home_virtual_display_preview_button",
            "home_virtual_display_web_view_button",
            "virtual_display_edit_button",
            "home_virtual_display_more_button"
        ] {
            let element = assertExists(app, identifier: identifier, timeout: 6)
            XCTAssertTrue(element.isHittable, "Element is not hittable: \(identifier)")
            XCTAssertTrue(window.frame.contains(element.frame), "Element is outside window: \(identifier)")
        }
    }

    @MainActor
    func testVirtualDisplayCardSurfaceSmoke_dashboardSkin() throws {
        let app = launchAppForSmoke(skinID: "dashboard")

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "home_virtual_display_surface",
                "home_dashboard_status_board",
                "home_virtual_display_card_grid",
                "home_virtual_display_card",
                "home_card_status_grid",
                "virtual_display_toggle_button",
                "home_virtual_display_preview_button",
                "home_virtual_display_web_view_button",
                "virtual_display_edit_button",
                "home_virtual_display_more_button"
            ],
            timeout: 6
        )
    }

    @MainActor
    func testDiagnosticsNavigationSmoke_baseline() throws {
        let app = launchAppForSmoke()

        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)

        assertAllExist(
            app,
            identifiers: [
                "detail_diagnostics",
                "diagnostics_intro_text",
                "support_bundle_export_button",
                "support_bundle_draft_panel",
                "diagnostics_technical_disclosure"
            ],
            timeout: 3
        )

        XCTAssertFalse(app.descendants(matching: .any)["support_bundle_copy_summary_button"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["support_bundle_reveal_button"].exists)
    }

    @MainActor
    func testDiagnosticsActionsRemainVisibleAtNarrowWindowSize() throws {
        let app = launchAppForSmoke(windowSize: (760, 640))
        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)
        let disclosure = assertExists(
            app,
            identifier: "diagnostics_technical_disclosure",
            timeout: 3
        )
        disclosure.tap()

        let window = app.windows.firstMatch
        for identifier in ["diagnostics_refresh_button", "diagnostics_open_data_directory_button"] {
            let element = assertExists(app, identifier: identifier, timeout: 5)
            XCTAssertTrue(window.frame.contains(element.frame), "Element is outside window: \(identifier)")
        }
    }

    @MainActor
    func testFirstTabFocusesAVisibleControl() throws {
        let app = launchAppForSmoke(windowSize: (760, 640), advanceFocus: true)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))

        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 2))
        XCTAssertTrue(window.frame.intersects(focused.frame))
        XCTAssertGreaterThan(focused.frame.width, 1)
        XCTAssertGreaterThan(focused.frame.height, 1)
    }

    @MainActor
    func testPreviewRecoveryRetryShowsRestartingState() throws {
        let app = launchAppForSmoke(scenario: "preview_recovery")
        assertAllExist(
            app,
            identifiers: [
                "capture_preview_failed_state",
                "capture_preview_retry_button",
                "capture_preview_close_button"
            ],
            timeout: 6
        )

        tapIdentifier(app, identifier: "capture_preview_retry_button")

        assertExists(app, identifier: "capture_preview_restarting_state", timeout: 2)
    }

    @MainActor
    func testPreviewRecoveryCloseReleasesWindowState() throws {
        let app = launchAppForSmoke(scenario: "preview_recovery")
        tapIdentifier(app, identifier: "capture_preview_close_button", timeout: 6)

        assertExists(app, identifier: "capture_preview_closed_state", timeout: 2)
    }

    @MainActor
    func testPreviewWindowWaitsForIdentityWithoutClosing() throws {
        let app = launchAppForSmoke(scenario: "preview_window_payload")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertTrue(window.exists)
        assertExists(app, identifier: "capture_preview_waiting_for_identity", timeout: 2)
    }
}
