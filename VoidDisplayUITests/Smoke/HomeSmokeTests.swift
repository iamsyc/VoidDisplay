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

            assertExists(app, identifier: "sidebar_monitor_screen").tap()
            assertExists(app, identifier: "detail_monitor_screen")
            assertExists(app, identifier: "capture_loading_displays")

            assertExists(app, identifier: "sidebar_screen_sharing").tap()
            assertExists(app, identifier: "detail_screen_sharing")
            assertExists(app, identifier: "share_start_service_button").tap()

            if waitForIdentifierByPolling(
                app,
                identifier: "share_loading_displays",
                timeout: 3
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
    func testVirtualDisplaySmoke_primaryRibbonPersistsAfterMenuSwitch() throws {
        let app = launchAppForSmoke(scenario: .baseline)

        assertExists(app, identifier: "sidebar_virtual_display").tap()
        assertExists(app, identifier: "detail_virtual_display")
        assertExists(app, identifier: "virtual_display_primary_ribbon")

        assertExists(app, identifier: "sidebar_screen").tap()
        assertExists(app, identifier: "detail_screen")

        assertExists(app, identifier: "sidebar_virtual_display").tap()
        assertExists(app, identifier: "detail_virtual_display")
        assertExists(app, identifier: "virtual_display_primary_ribbon")
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
        tapWhenHittable(saveOnlyButton, in: saveOnlyApp)
        XCTAssertFalse(saveOnlyForm.waitForExistence(timeout: 0.3))
        saveOnlyApp.terminate()

        let saveAndRebuildApp = launchAppForSmoke(scenario: .baseline)
        assertExists(saveAndRebuildApp, identifier: "sidebar_virtual_display").tap()
        assertExists(saveAndRebuildApp, identifier: "detail_virtual_display")
        assertExists(saveAndRebuildApp, identifier: "virtual_display_edit_button").tap()
        let saveAndRebuildForm = assertExists(saveAndRebuildApp, identifier: "edit_virtual_display_form")
        assertExists(saveAndRebuildApp, identifier: "virtual_display_edit_mode_hidpi_toggle").tap()
        let saveAndRebuildAction = assertExists(
            saveAndRebuildApp,
            identifier: "virtual_display_edit_save_and_rebuild_button"
        )
        tapWhenHittable(saveAndRebuildAction, in: saveAndRebuildApp)
        XCTAssertFalse(saveAndRebuildForm.waitForExistence(timeout: 0.3))
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
