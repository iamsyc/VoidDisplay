//
//  VoidDisplayUITests.swift
//  VoidDisplayUITests
//
//

import XCTest

final class HomeSmokeTests: XCTestCase {
    private let maxLoadingSmokePortAttempts = 5

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
        let displaysSidebar = smokeElement(app, identifier: "sidebar_screen")
        let virtualDisplaySidebar = smokeElement(app, identifier: "sidebar_virtual_display")
        let monitorSidebar = smokeElement(app, identifier: "sidebar_monitor_screen")
        let sharingSidebar = smokeElement(app, identifier: "sidebar_screen_sharing")

        assertAllExist(
            app,
            identifiers: [
                "home_sidebar",
                "sidebar_screen",
                "sidebar_virtual_display",
                "sidebar_monitor_screen",
                "sidebar_screen_sharing",
                "detail_screen",
                "displays_shell",
                "displays_shell_entries",
                "displays_shell_virtual_display_entry",
                "displays_shell_monitor_entry",
                "displays_shell_lan_web_view_entry",
                "displays_shell_diagnostics_support_entry",
                "displays_list",
                "displays_open_system_settings"
            ],
            timeout: 6
        )

        tapIdentifier(app, identifier: "displays_shell_virtual_display_entry", timeout: 1.5)
        assertAllExist(
            app,
            identifiers: [
                "detail_virtual_display",
                "virtual_display_add_button",
                "virtual_display_primary_ribbon"
            ],
            timeout: 1.5
        )

        displaysSidebar.tap()
        assertAllExist(
            app,
            identifiers: ["detail_screen", "displays_shell_monitor_entry"],
            timeout: 1.5
        )
        tapIdentifier(app, identifier: "displays_shell_monitor_entry", timeout: 1.5)
        assertAllExist(
            app,
            identifiers: ["detail_monitor_screen"],
            timeout: 1.5
        )

        displaysSidebar.tap()
        assertAllExist(
            app,
            identifiers: ["detail_screen", "displays_shell_lan_web_view_entry"],
            timeout: 1.5
        )
        tapIdentifier(app, identifier: "displays_shell_lan_web_view_entry", timeout: 1.5)
        assertAllExist(
            app,
            identifiers: ["detail_screen_sharing"],
            timeout: 1.5
        )

        displaysSidebar.tap()
        assertAllExist(
            app,
            identifiers: ["detail_screen", "displays_shell_diagnostics_support_entry"],
            timeout: 1.5
        )
        tapIdentifier(app, identifier: "displays_shell_diagnostics_support_entry", timeout: 1.5)
        assertAllExist(
            app,
            identifiers: ["detail_support_center"],
            timeout: 2
        )

        virtualDisplaySidebar.tap()
        assertAllExist(
            app,
            identifiers: [
                "detail_virtual_display",
                "virtual_display_add_button",
                "virtual_display_primary_ribbon"
            ],
            timeout: 1.5
        )

        monitorSidebar.tap()
        let didShowMonitorDetail = waitForIdentifierByPolling(
            app,
            identifier: "detail_monitor_screen",
            timeout: 1.2,
            activateBeforePolling: true
        )
        if !didShowMonitorDetail {
            print("AX DEBUG START")
            print(app.debugDescription)
            print("AX DEBUG END")
        }
        XCTAssertTrue(
            didShowMonitorDetail,
            """
            detail_monitor_screen did not appear after tapping sidebar_monitor_screen.
            detailStates=\(detailVisibilitySummary(in: app))
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        sharingSidebar.tap()
        assertAllExist(
            app,
            identifiers: ["detail_screen_sharing"],
            timeout: 1.2
        )
        virtualDisplaySidebar.tap()
        assertAllExist(
            app,
            identifiers: ["virtual_display_primary_ribbon"],
            timeout: 1.2
        )
    }

    @MainActor
    func testDisplaysSurfaceConvergenceSmoke_baseline() throws {
        let app = launchAppForSmoke(scenario: .baseline)

        assertAllExist(
            app,
            identifiers: [
                "detail_screen",
                "displays_surface_list",
                "display_surface_row",
                "displays_surface_detail",
                "displays_surface_kind_value",
                "displays_surface_identity_value",
                "displays_virtual_display_status"
            ],
            timeout: 6
        )
        assertDisplaysSurfaceStatusArea(in: app)
        assertDisplaysSurfaceActionArea(in: app)

        tapDisplaysSurfaceAction(app, identifier: "displays_action_open_monitor")
        assertAllExist(app, identifiers: ["detail_monitor_screen"], timeout: 1.5)

        openDisplaysFromSidebar(in: app)
        assertDisplaysSurfaceActionArea(in: app)
        tapDisplaysSurfaceAction(app, identifier: "displays_action_open_lan_web_view")
        assertAllExist(app, identifiers: ["detail_screen_sharing"], timeout: 1.5)

        openDisplaysFromSidebar(in: app)
        assertDisplaysSurfaceActionArea(in: app)
        tapDisplaysSurfaceAction(app, identifier: "displays_action_manage_virtual_display")
        assertAllExist(app, identifiers: ["detail_virtual_display"], timeout: 1.5)

        openDisplaysFromSidebar(in: app)
        assertDisplaysSurfaceActionArea(in: app)
        tapDisplaysSurfaceAction(app, identifier: "displays_action_open_diagnostics_support")
        assertAllExist(app, identifiers: ["detail_support_center"], timeout: 2)
    }

    @MainActor
    private func assertDisplaysSurfaceStatusArea(in app: XCUIApplication) {
        assertAllExist(
            app,
            identifiers: [
                "displays_monitor_status",
                "displays_lan_web_view_status",
                "displays_viewer_count",
                "displays_capture_intent_status",
                "displays_lease_status",
                "displays_last_failure_code"
            ],
            timeout: 1.5
        )
    }

    @MainActor
    private func assertDisplaysSurfaceActionArea(in app: XCUIApplication) {
        assertAllExist(
            app,
            identifiers: [
                "displays_surface_actions",
                "displays_action_manage_virtual_display",
                "displays_action_open_monitor",
                "displays_action_stop_monitor",
                "displays_action_open_lan_web_view",
                "displays_action_stop_lan_web_view",
                "displays_action_stop_web_service",
                "displays_action_open_diagnostics_support"
            ],
            timeout: 1.5
        )
    }

    @MainActor
    private func openDisplaysFromSidebar(in app: XCUIApplication) {
        smokeElement(app, identifier: "sidebar_screen").tap()
        assertAllExist(
            app,
            identifiers: [
                "detail_screen",
                "displays_surface_detail"
            ],
            timeout: 1.5
        )
    }

    @MainActor
    private func tapDisplaysSurfaceAction(
        _ app: XCUIApplication,
        identifier: String
    ) {
        tapIdentifier(app, identifier: identifier, timeout: 1.5)
    }

    @MainActor
    func testSupportCenterNavigationSmoke_baseline() throws {
        let app = launchAppForSmoke(scenario: .baseline)

        assertAllExist(
            app,
            identifiers: [
                "home_sidebar",
                "sidebar_support_center"
            ],
            timeout: 6
        )

        tapIdentifier(app, identifier: "sidebar_support_center", timeout: 2)

        assertAllExist(
            app,
            identifiers: [
                "detail_support_center",
                "support_center_intro_text",
                "support_center_export_button",
                "support_bundle_draft_panel",
                "support_bundle_draft_section",
                "support_center_issue_type_title",
                "support_center_issue_type_picker",
                "support_center_issue_type_selected_description",
                "support_center_issue_type_recommendation",
                "support_center_apply_recommended_diagnostics_button",
                "support_bundle_happened_title",
                "support_bundle_happened_description",
                "support_bundle_reproduction_title",
                "support_bundle_reproduction_description",
                "support_bundle_expected_title",
                "support_bundle_expected_description",
                "support_bundle_diagnostics_description",
                "support_center_technical_disclosure"
            ],
            timeout: 3
        )

        let draftSection = assertExists(app, identifier: "support_bundle_draft_panel", timeout: 1)
        let exportButton = assertExists(app, identifier: "support_center_export_button", timeout: 1)
        let technicalDisclosure = assertExists(app, identifier: "support_center_technical_disclosure", timeout: 1)
        XCTAssertLessThan(
            draftSection.frame.minY,
            technicalDisclosure.frame.minY,
            "support bundle section should appear before technical information"
        )
        XCTAssertFalse(app.descendants(matching: .any)["support_center_copy_summary_button"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["support_center_reveal_bundle_button"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["support_center_recent_issues"].exists)
        XCTAssertFalse(exportButton.label.isEmpty)
    }

    @MainActor
    func testSupportCenterEmptyExportShowsValidationNearExportButton() throws {
        let app = launchAppForSmoke(scenario: .baseline)

        tapIdentifier(app, identifier: "sidebar_support_center", timeout: 6)
        let exportButton = assertExists(app, identifier: "support_center_export_button", timeout: 3)
        tapByCoordinate(exportButton, timeout: 1, requireExistenceCheck: false)

        let validationMessage = assertExists(app, identifier: "support_center_validation_message", timeout: 2)
        let issueTypeTitle = assertExists(app, identifier: "support_center_issue_type_title", timeout: 1)
        XCTAssertLessThan(
            validationMessage.frame.maxY,
            issueTypeTitle.frame.minY,
            "validation message should appear near the export button before the issue type controls"
        )
    }

    @MainActor
    func testSupportCenterExportShowsCompletionWithoutDuplicateHistory() throws {
        let app = XCUIApplication()
        configureAppForUITestLaunch(app)
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = SmokeScenario.baseline.rawValue
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_ISSUE_TYPE"] = "cannotShare"
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_HAPPENED"] = "Remote side disconnects immediately."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_REPRODUCTION"] = "1. Start sharing. 2. Open the remote URL."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_EXPECTED"] = "The remote side should stay connected."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_INCLUDE_LOGS"] = "1"
        app.launch()
        app.activate()

        tapIdentifier(app, identifier: "sidebar_support_center", timeout: 6)
        let happenedField = assertExists(app, identifier: "support_bundle_happened_field", timeout: 3)
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                (happenedField.value as? String) == "Remote side disconnects immediately."
            }
        )
        let exportButton = assertExists(app, identifier: "support_center_export_button", timeout: 3)
        tapByCoordinate(exportButton, timeout: 1, requireExistenceCheck: false)

        assertAllExist(
            app,
            identifiers: [
                "support_center_completion_section",
                "support_center_completion_next_step",
                "support_center_copy_summary_button",
                "support_center_reveal_bundle_button",
                "support_center_new_feedback_button"
            ],
            timeout: 8
        )

        XCTAssertFalse(app.descendants(matching: .any)["support_center_history_section"].exists)
    }

    @MainActor
    func testSupportCenterExportFailureShowsErrorBannerOnSupportCenter() throws {
        let app = XCUIApplication()
        configureAppForUITestLaunch(app)
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = SmokeScenario.baseline.rawValue
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_HAPPENED"] = "Export should fail."
        app.launchEnvironment["VOIDDISPLAY_FEEDBACK_EXPORT_FAILURE_MESSAGE"] = "Injected export failure"
        app.launch()
        app.activate()

        tapIdentifier(app, identifier: "sidebar_support_center", timeout: 6)
        let happenedField = assertExists(app, identifier: "support_bundle_happened_field", timeout: 3)
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                (happenedField.value as? String) == "Export should fail."
            }
        )
        let exportButton = assertExists(app, identifier: "support_center_export_button", timeout: 3)
        tapByCoordinate(exportButton, timeout: 1, requireExistenceCheck: false)

        assertAllExist(
            app,
            identifiers: [
                "support_center_error_banner",
                "support_center_error_title",
                "support_center_error_message"
            ],
            timeout: 5
        )
        let titleText = accessibilityText(
            for: smokeElement(app, identifier: "support_center_error_title")
        )
        XCTAssertTrue(
            ["Export Failed", "导出失败"].contains(titleText),
            "Unexpected support center error title: \(titleText)"
        )
        XCTAssertEqual(
            accessibilityText(
                for: smokeElement(app, identifier: "support_center_error_message")
            ),
            "Injected export failure"
        )
        XCTAssertFalse(app.alerts.element.exists)
        XCTAssertTrue(app.descendants(matching: .any)["detail_support_center"].exists)
    }

    @MainActor
    func testVirtualDisplayEditSmoke_directSaveActionsWithoutConfirmationAlert() throws {
        let app = launchAppForSmoke(scenario: .baseline)
        let detail = openVirtualDisplayDetail(in: app)

        let initialEditState = openVirtualDisplayEditForm(in: app, detail: detail)
        let initialValue = boolValue(forToggle: initialEditState.toggle)
        let initialRebuildCount = rebuildRequestCount(in: detail)
        tapFast(
            initialEditState.toggle,
            in: app
        ) {
            boolValue(forToggle: initialEditState.toggle) != initialValue
        }
        let saveOnlyButton = initialEditState.saveOnlyButton
        let saveAndRebuildButton = initialEditState.saveAndRebuildButton
        XCTAssertTrue(saveAndRebuildButton.isEnabled)
        tapFast(
            saveOnlyButton,
            in: app
        ) {
            !initialEditState.form.exists
        }
        XCTAssertTrue(waitForDisappearance(of: initialEditState.form, timeout: 1.5))
        XCTAssertEqual(rebuildRequestCount(in: detail), initialRebuildCount)

        let saveOnlyPersistedState = reopenEditFormAndReadHiDPI(in: app, detail: detail)
        XCTAssertEqual(saveOnlyPersistedState.value, !initialValue)
        tapFast(
            saveOnlyPersistedState.toggle,
            in: app
        ) {
            boolValue(forToggle: saveOnlyPersistedState.toggle) == initialValue
        }
        tapFast(
            saveOnlyPersistedState.saveAndRebuildButton,
            in: app
        ) {
            !saveOnlyPersistedState.form.exists
        }
        XCTAssertTrue(waitForDisappearance(of: saveOnlyPersistedState.form, timeout: 1.5))
        XCTAssertTrue(
            waitForRebuildRequestCount(
                in: detail,
                expected: initialRebuildCount + 1,
                timeout: 2
            )
        )

        let saveAndRebuildPersistedState = reopenEditFormAndReadHiDPI(in: app, detail: detail)
        XCTAssertEqual(saveAndRebuildPersistedState.value, initialValue)
        tapFast(
            saveAndRebuildPersistedState.cancelButton,
            in: app
        ) {
            !saveAndRebuildPersistedState.form.exists
        }
        XCTAssertTrue(waitForDisappearance(of: saveAndRebuildPersistedState.form, timeout: 1.5))
    }

    @MainActor
    func testPermissionDeniedSmoke_captureAndShare() throws {
        let app = launchAppForSmoke(scenario: .permissionDenied)
        let monitorSidebar = smokeElement(app, identifier: "sidebar_monitor_screen")
        let sharingSidebar = smokeElement(app, identifier: "sidebar_screen_sharing")

        assertAllExist(
            app,
            identifiers: ["sidebar_monitor_screen", "sidebar_screen_sharing"],
            timeout: 2
        )
        monitorSidebar.tap()
        assertAllExist(
            app,
            identifiers: [
                "detail_monitor_screen",
                "capture_permission_guide",
                "capture_open_settings_button",
                "capture_request_permission_button",
                "capture_refresh_button"
            ],
            timeout: 1.2
        )

        sharingSidebar.tap()
        assertAllExist(
            app,
            identifiers: [
                "detail_screen_sharing",
                "share_permission_guide",
                "share_open_settings_button",
                "share_request_permission_button",
                "share_refresh_button"
            ],
            timeout: 1.2
        )
    }

    @MainActor
    func testLoadingSmoke_captureAndShareShowVisibleLoadingState() throws {
        let candidatePorts = UITestPortAllocator.randomPortCandidates(count: maxLoadingSmokePortAttempts)
        var attemptedPorts: [UInt16] = []
        var lastPortError: String?

        for candidatePort in candidatePorts {
            attemptedPorts.append(candidatePort)
            let app = launchAppForSmoke(
                scenario: .displayCatalogLoading,
                preferredPort: candidatePort
            )
            let monitorSidebar = smokeElement(app, identifier: "sidebar_monitor_screen")
            let sharingSidebar = smokeElement(app, identifier: "sidebar_screen_sharing")
            let startServiceButton = smokeElement(app, identifier: "share_start_service_button")

            assertAllExist(
                app,
                identifiers: ["sidebar_monitor_screen", "sidebar_screen_sharing"],
                timeout: 2
            )
            monitorSidebar.tap()
            assertAllExist(
                app,
                identifiers: [
                    "detail_monitor_screen",
                    "capture_loading_displays"
                ],
                timeout: 1.2
            )

            sharingSidebar.tap()
            assertAllExist(
                app,
                identifiers: [
                    "detail_screen_sharing",
                    "share_start_service_button"
                ],
                timeout: 1.2
            )
            startServiceButton.tap()

            if waitForIdentifierByPolling(
                app,
                identifier: "share_loading_displays",
                timeout: 1.0
            ) {
                app.terminate()
                return
            }

            lastPortError = inlinePortErrorText(app)
            if isRetryablePortInUseError(lastPortError) {
                app.terminate()
                continue
            }

            let visibleStates = sharePageVisibleStates(app)
            app.terminate()
            XCTFail(
                "Sharing loading state did not appear. attemptedPorts=\(attemptedPorts), " +
                "lastPortError=\(lastPortError ?? "none"), " +
                "visibleStates=\(visibleStates)"
            )
            return
        }

        XCTFail(
            "Failed to start sharing service for loading smoke after retrying candidate ports. " +
            "attemptedPorts=\(attemptedPorts), lastPortError=\(lastPortError ?? "none")"
        )
    }

    @MainActor
    func testVirtualDisplaySmoke_rebuildIndicators() throws {
        let app = launchAppForSmoke(scenario: .baseline)
        _ = openVirtualDisplayDetail(in: app)
        let showRebuildingButton = smokeElement(app, identifier: "virtual_display_show_rebuilding_test_button")
        let showRebuildFailedButton = smokeElement(app, identifier: "virtual_display_show_rebuild_failed_test_button")

        assertAllExist(
            app,
            identifiers: [
                "detail_virtual_display",
                "virtual_display_show_rebuilding_test_button",
                "virtual_display_show_rebuild_failed_test_button"
            ],
            timeout: 1.2
        )

        let rebuildProgress = smokeElement(app, identifier: "virtual_display_rebuild_progress")
        let retryButton = smokeElement(app, identifier: "virtual_display_rebuild_retry_button")

        tapByCoordinate(showRebuildingButton, timeout: 1, requireExistenceCheck: false)
        assertElementsExist([("virtual_display_rebuild_progress", rebuildProgress)], timeout: 1.2)
        XCTAssertTrue(rebuildProgress.exists)

        tapByCoordinate(showRebuildFailedButton, timeout: 1, requireExistenceCheck: false)
        XCTAssertTrue(waitForDisappearance(of: rebuildProgress, timeout: 1.2))
        assertElementsExist([("virtual_display_rebuild_retry_button", retryButton)], timeout: 1.2)
        XCTAssertTrue(retryButton.isEnabled)
    }

    @MainActor
    func testVirtualDisplaySmoke_rebuildFailedRowShowsRetry() throws {
        let app = launchAppForSmoke(scenario: .virtualDisplayRebuildFailed)
        _ = openVirtualDisplayDetail(in: app)

        assertAllExist(
            app,
            identifiers: [
                "detail_virtual_display",
                "virtual_display_rebuild_retry_button"
            ],
            timeout: 1.2
        )

        let retryButton = smokeElement(app, identifier: "virtual_display_rebuild_retry_button")
        XCTAssertTrue(retryButton.isEnabled)
        XCTAssertFalse(smokeElement(app, identifier: "virtual_display_rebuild_progress").exists)
    }

    @MainActor
    private func boolValue(forToggle toggle: XCUIElement) -> Bool {
        if let numberValue = toggle.value as? NSNumber {
            return numberValue.intValue != 0
        }
        if let stringValue = toggle.value as? String {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "on"].contains(normalized) {
                return true
            }
            if ["0", "false", "off"].contains(normalized) {
                return false
            }
        }
        XCTFail("Unexpected toggle value: \(String(describing: toggle.value))")
        return false
    }

    @MainActor
    private func openVirtualDisplayDetail(in app: XCUIApplication) -> XCUIElement {
        assertAllExist(
            app,
            identifiers: ["sidebar_virtual_display"],
            timeout: 1.2
        )
        smokeElement(app, identifier: "sidebar_virtual_display").tap()
        assertAllExist(
            app,
            identifiers: ["detail_virtual_display"],
            timeout: 1.2
        )
        return smokeElement(app, identifier: "detail_virtual_display")
    }

    @MainActor
    private func openVirtualDisplayEditForm(
        in app: XCUIApplication,
        detail: XCUIElement
    ) -> (
        form: XCUIElement,
        toggle: XCUIElement,
        saveOnlyButton: XCUIElement,
        saveAndRebuildButton: XCUIElement,
        cancelButton: XCUIElement
    ) {
        let form = smokeElement(app, identifier: "edit_virtual_display_form")
        let toggle = smokeElement(app, identifier: "virtual_display_edit_mode_hidpi_toggle")
        let saveOnlyButton = smokeElement(app, identifier: "virtual_display_edit_save_only_button")
        let saveAndRebuildButton = smokeElement(app, identifier: "virtual_display_edit_save_and_rebuild_button")
        let cancelButton = smokeElement(app, identifier: "virtual_display_edit_cancel_button")
        assertAllExist(
            app,
            identifiers: ["detail_virtual_display", "virtual_display_open_edit_test_button"],
            timeout: 1.2
        )
        XCTAssertTrue(detail.exists, "Virtual display detail is unavailable.")
        let openEditButton = smokeElement(app, identifier: "virtual_display_open_edit_test_button")
        tapByCoordinate(
            openEditButton,
            timeout: 1,
            requireExistenceCheck: false
        )
        if waitForIdentifierByPolling(app, identifier: "edit_virtual_display_form", timeout: 0.9) {
            assertAllExist(
                app,
                identifiers: [
                    "edit_virtual_display_form",
                    "virtual_display_edit_mode_hidpi_toggle",
                    "virtual_display_edit_save_only_button",
                    "virtual_display_edit_save_and_rebuild_button",
                    "virtual_display_edit_cancel_button"
                ],
                timeout: 0.6
            )
        } else {
            let retryOpenEditButton = smokeElement(app, identifier: "virtual_display_open_edit_test_button")
            tapByCoordinate(
                retryOpenEditButton,
                timeout: 0.6,
                requireExistenceCheck: false
            )
            assertAllExist(
                app,
                identifiers: [
                    "edit_virtual_display_form",
                    "virtual_display_edit_mode_hidpi_toggle",
                    "virtual_display_edit_save_only_button",
                    "virtual_display_edit_save_and_rebuild_button",
                    "virtual_display_edit_cancel_button"
                ],
                timeout: 1.5
            )
        }
        return (
            form: form,
            toggle: toggle,
            saveOnlyButton: saveOnlyButton,
            saveAndRebuildButton: saveAndRebuildButton,
            cancelButton: cancelButton
        )
    }

    @MainActor
    private func reopenEditFormAndReadHiDPI(
        in app: XCUIApplication,
        detail: XCUIElement
    ) -> (
        form: XCUIElement,
        toggle: XCUIElement,
        saveOnlyButton: XCUIElement,
        saveAndRebuildButton: XCUIElement,
        cancelButton: XCUIElement,
        value: Bool
    ) {
        let state = openVirtualDisplayEditForm(in: app, detail: detail)
        return (
            state.form,
            state.toggle,
            state.saveOnlyButton,
            state.saveAndRebuildButton,
            state.cancelButton,
            boolValue(forToggle: state.toggle)
        )
    }

    @MainActor
    private func rebuildRequestCount(in detail: XCUIElement) -> Int {
        let rawValue = if let value = detail.value as? String, !value.isEmpty {
            value
        } else {
            detail.label
        }
        guard let count = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            XCTFail("Unexpected rebuild request count: \(rawValue)")
            return -1
        }
        return count
    }

    @MainActor
    private func waitForRebuildRequestCount(
        in detail: XCUIElement,
        expected: Int,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if rebuildRequestCount(in: detail) == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return rebuildRequestCount(in: detail) == expected
    }

    @MainActor
    private func inlinePortErrorText(_ app: XCUIApplication) -> String? {
        let errorText = app.descendants(matching: .any)
            .matching(identifier: "share_port_error_text")
            .firstMatch
        guard errorText.exists else { return nil }

        let labelText = errorText.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !labelText.isEmpty { return labelText }

        if let valueText = (errorText.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !valueText.isEmpty {
            return valueText
        }
        return nil
    }

    @MainActor
    private func accessibilityText(for element: XCUIElement) -> String {
        let labelText = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if labelText.isEmpty == false {
            return labelText
        }

        if let valueText = (element.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           valueText.isEmpty == false {
            return valueText
        }

        return ""
    }

    private func isRetryablePortInUseError(_ message: String?) -> Bool {
        guard let normalizedMessage = message?.lowercased(), !normalizedMessage.isEmpty else {
            return false
        }

        let markers = [
            "port in use",
            "address already in use",
            "eaddrinuse",
            "已被占用",
            "被占用",
            "端口",
            "occupied"
        ]

        return markers.contains { normalizedMessage.contains($0) }
    }

    @MainActor
    private func detailVisibilitySummary(in app: XCUIApplication) -> String {
        [
            "detail_screen",
            "detail_virtual_display",
            "detail_monitor_screen",
            "detail_screen_sharing",
            "capture_choose_root",
            "share_content_root"
        ]
        .map { identifier in
            "\(identifier)=\(smokeElement(app, identifier: identifier).exists)"
        }
        .joined(separator: ", ")
    }

    @MainActor
    private func sharePageVisibleStates(_ app: XCUIApplication) -> [String] {
        let identifiers = [
            "share_permission_guide",
            "share_loading_permission",
            "share_start_service_button",
            "share_loading_displays",
            "share_displays_list",
            "share_displays_empty_state"
        ]

        return identifiers.filter { identifier in
            app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
                .exists
        }
    }
}
