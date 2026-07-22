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
                "home_add_virtual_display_button",
                "home_sharing_settings_popover_button",
                "home_refresh_button",
                "home_virtual_display_list_row"
            ],
            timeout: 6
        )
        assertHomePageActionsAreInToolbar(app)

        XCTAssertFalse(app.descendants(matching: .any)["sidebar_displays"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_virtual_display"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_screen_preview"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_screen_sharing"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["home_virtual_display_title"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["home_header_screen_recording_permission_status"].exists)

        tapIdentifier(app, identifier: "sidebar_diagnostics")
        assertAllExist(app, identifiers: ["detail_diagnostics"], timeout: 1.5)
        assertHomePageActionsAreAbsent(app)

        tapIdentifier(app, identifier: "sidebar_home")
        assertAllExist(app, identifiers: ["detail_home", "home_virtual_display_list_row"], timeout: 1.5)
        assertHomePageActionsAreInToolbar(app)
    }

    @MainActor
    func testScreenRecordingPermissionAppearsInHeaderOnlyWhenActionIsRequired() throws {
        let app = launchAppForSmoke(scenario: "permission_denied")

        assertAllExist(
            app,
            identifiers: [
                "home_header_screen_recording_permission_status",
                "home_open_privacy_settings_button"
            ],
            timeout: 6
        )
    }

    @MainActor
    func testVirtualDisplayListSurfaceSmoke_baseline() throws {
        let app = launchAppForSmoke()

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "home_virtual_display_surface",
                "home_summary_status_strip",
                "home_sharing_settings_popover_button",
                "home_virtual_display_list",
                "home_virtual_display_list_row",
                "home_item_status_grid",
                "virtual_display_toggle_button",
                "home_virtual_display_preview_toggle",
                "home_virtual_display_web_view_toggle",
                "virtual_display_edit_button",
                "home_virtual_display_more_button",
                "home_add_virtual_display_button"
            ],
            timeout: 6
        )
        assertHomePageActionsAreInToolbar(app)

        let rows = app.descendants(matching: .any)
            .matching(identifier: "home_virtual_display_list_row")
            .allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertEqual(rows[0].frame.minX, rows[1].frame.minX, accuracy: 2)
        XCTAssertGreaterThan(rows[1].frame.minY, rows[0].frame.minY)
        XCTAssertFalse(app.descendants(matching: .any)["home_virtual_display_card_grid"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["home_virtual_display_card"].exists)
        XCTAssertTrue(app.switches.matching(identifier: "home_virtual_display_preview_toggle").firstMatch.exists)
        XCTAssertTrue(app.switches.matching(identifier: "home_virtual_display_web_view_toggle").firstMatch.exists)
        XCTAssertFalse(app.buttons["home_virtual_display_preview_button"].exists)
        XCTAssertFalse(app.buttons["home_virtual_display_web_view_button"].exists)

        tapIdentifier(app, identifier: "home_sharing_settings_popover_button")
        assertAllExist(
            app,
            identifiers: [
                "home_sharing_settings_panel",
                "home_sharing_performance_picker",
                "home_sharing_port_input",
                "home_sharing_screen_recording_permission_status"
            ],
            timeout: 2
        )
    }

    @MainActor
    func testListActionsRemainVisibleAtNarrowWindowSize() throws {
        let app = launchAppForSmoke(windowSize: (760, 640))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))
        assertHomePageActionsAreInToolbar(app)

        for identifier in [
            "home_add_virtual_display_button",
            "home_sharing_settings_popover_button",
            "home_refresh_button",
            "virtual_display_toggle_button",
            "home_virtual_display_preview_toggle",
            "home_virtual_display_web_view_toggle",
            "virtual_display_edit_button",
            "home_virtual_display_more_button"
        ] {
            let element = assertExists(app, identifier: identifier, timeout: 6)
            XCTAssertTrue(element.isHittable, "Element is not hittable: \(identifier)")
            XCTAssertTrue(window.frame.contains(element.frame), "Element is outside window: \(identifier)")
        }
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
                "diagnostics_health_summary_panel",
                "diagnostics_refresh_button",
                "support_bundle_export_button",
                "support_bundle_draft_panel",
                "support_bundle_contents_summary",
                "support_bundle_local_storage_notice",
                "diagnostics_technical_disclosure"
            ],
            timeout: 3
        )

        let healthPanel = smokeElement(app, identifier: "diagnostics_health_summary_panel")
        let draftPanel = smokeElement(app, identifier: "support_bundle_draft_panel")
        let technicalDisclosure = smokeElement(app, identifier: "diagnostics_technical_disclosure")
        let reproductionField = smokeElement(app, identifier: "support_bundle_reproduction_field")
        let expectedField = smokeElement(app, identifier: "support_bundle_expected_field")
        XCTAssertLessThan(healthPanel.frame.minY, draftPanel.frame.minY)
        XCTAssertLessThan(draftPanel.frame.minY, technicalDisclosure.frame.minY)
        XCTAssertEqual(reproductionField.frame.minY, expectedField.frame.minY, accuracy: 2)
        XCTAssertTrue(app.switches["support_bundle_include_log_toggle"].exists)
        XCTAssertTrue(app.switches["support_bundle_include_crash_toggle"].exists)
        XCTAssertTrue(app.switches["support_bundle_include_configs_toggle"].exists)

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
        let reproductionField = smokeElement(app, identifier: "support_bundle_reproduction_field")
        let expectedField = smokeElement(app, identifier: "support_bundle_expected_field")
        XCTAssertLessThan(reproductionField.frame.maxY, expectedField.frame.minY)
        let scrollView = try XCTUnwrap(
            app.scrollViews.allElementsBoundByIndex.max { lhs, rhs in
                lhs.frame.width < rhs.frame.width
            }
        )
        for _ in 0..<4 where disclosure.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(disclosure.isHittable)
        disclosure.coordinate(
            withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)
        ).click()

        let window = app.windows.firstMatch
        let openDirectoryButton = assertExists(
            app,
            identifier: "diagnostics_open_data_directory_button",
            timeout: 5
        )
        XCTAssertTrue(window.frame.contains(openDirectoryButton.frame))
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

    @MainActor
    private func assertHomePageActionsAreInToolbar(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toolbar = app.toolbars.firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 2), "Missing window toolbar", file: file, line: line)

        for identifier in homePageActionIdentifiers {
            let element = toolbar.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            XCTAssertTrue(
                element.waitForExistence(timeout: 2),
                "Page action is outside the toolbar: \(identifier)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func assertHomePageActionsAreAbsent(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in homePageActionIdentifiers {
            let element = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            XCTAssertFalse(
                element.waitForExistence(timeout: 0.5),
                "Home page action remained visible outside Home: \(identifier)",
                file: file,
                line: line
            )
        }
    }

    private var homePageActionIdentifiers: [String] {
        [
            "home_refresh_button",
            "home_sharing_settings_popover_button",
            "home_add_virtual_display_button"
        ]
    }
}
