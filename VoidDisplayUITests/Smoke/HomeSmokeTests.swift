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
        let virtualDisplaySidebar = smokeElement(app, identifier: "sidebar_virtual_display")
        let monitorSidebar = smokeElement(app, identifier: "sidebar_monitor_screen")
        let sharingSidebar = smokeElement(app, identifier: "sidebar_screen_sharing")
        let monitorDetail = smokeElement(app, identifier: "detail_monitor_screen")
        let sharingDetail = smokeElement(app, identifier: "detail_screen_sharing")
        let virtualDisplayRibbon = smokeElement(app, identifier: "virtual_display_primary_ribbon")

        assertAllExist(
            app,
            identifiers: [
                "home_sidebar",
                "sidebar_screen",
                "sidebar_virtual_display",
                "sidebar_monitor_screen",
                "sidebar_screen_sharing",
                "detail_screen",
                "displays_open_system_settings"
            ],
            timeout: 3
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
        assertElementsExist([("detail_monitor_screen", monitorDetail)], timeout: 1.2)

        sharingSidebar.tap()
        assertElementsExist([("detail_screen_sharing", sharingDetail)], timeout: 1.2)
        virtualDisplaySidebar.tap()
        assertElementsExist([("virtual_display_primary_ribbon", virtualDisplayRibbon)], timeout: 1.2)
    }

    @MainActor
    func testVirtualDisplayEditSmoke_directSaveActionsWithoutConfirmationAlert() throws {
        let app = launchAppForSmoke(scenario: .baseline)
        let detail = openVirtualDisplayDetail(in: app)
        let openEditButton = smokeElement(app, identifier: "virtual_display_open_edit_test_button")

        let initialEditState = openVirtualDisplayEditForm(
            in: app,
            detail: detail,
            openEditButton: openEditButton
        )
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

        let saveOnlyPersistedState = reopenEditFormAndReadHiDPI(
            in: app,
            detail: detail,
            openEditButton: openEditButton
        )
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

        let saveAndRebuildPersistedState = reopenEditFormAndReadHiDPI(
            in: app,
            detail: detail,
            openEditButton: openEditButton
        )
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
        let monitorDetail = smokeElement(app, identifier: "detail_monitor_screen")
        let captureGuide = smokeElement(app, identifier: "capture_permission_guide")
        let captureOpenSettings = smokeElement(app, identifier: "capture_open_settings_button")
        let captureRequest = smokeElement(app, identifier: "capture_request_permission_button")
        let captureRefresh = smokeElement(app, identifier: "capture_refresh_button")
        let sharingDetail = smokeElement(app, identifier: "detail_screen_sharing")
        let shareGuide = smokeElement(app, identifier: "share_permission_guide")
        let shareOpenSettings = smokeElement(app, identifier: "share_open_settings_button")
        let shareRequest = smokeElement(app, identifier: "share_request_permission_button")
        let shareRefresh = smokeElement(app, identifier: "share_refresh_button")

        assertAllExist(
            app,
            identifiers: ["sidebar_monitor_screen", "sidebar_screen_sharing"],
            timeout: 2
        )
        monitorSidebar.tap()
        assertElementsExist(
            [
                ("detail_monitor_screen", monitorDetail),
                ("capture_permission_guide", captureGuide),
                ("capture_open_settings_button", captureOpenSettings),
                ("capture_request_permission_button", captureRequest),
                ("capture_refresh_button", captureRefresh)
            ],
            timeout: 1.2
        )

        sharingSidebar.tap()
        assertElementsExist(
            [
                ("detail_screen_sharing", sharingDetail),
                ("share_permission_guide", shareGuide),
                ("share_open_settings_button", shareOpenSettings),
                ("share_request_permission_button", shareRequest),
                ("share_refresh_button", shareRefresh)
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
            let monitorDetail = smokeElement(app, identifier: "detail_monitor_screen")
            let captureLoading = smokeElement(app, identifier: "capture_loading_displays")
            let sharingDetail = smokeElement(app, identifier: "detail_screen_sharing")
            let startServiceButton = smokeElement(app, identifier: "share_start_service_button")
            let shareLoading = smokeElement(app, identifier: "share_loading_displays")

            assertAllExist(
                app,
                identifiers: ["sidebar_monitor_screen", "sidebar_screen_sharing"],
                timeout: 2
            )
            monitorSidebar.tap()
            assertElementsExist(
                [
                    ("detail_monitor_screen", monitorDetail),
                    ("capture_loading_displays", captureLoading)
                ],
                timeout: 1.2
            )

            sharingSidebar.tap()
            assertElementsExist(
                [
                    ("detail_screen_sharing", sharingDetail),
                    ("share_start_service_button", startServiceButton)
                ],
                timeout: 1.2
            )
            startServiceButton.tap()

            if waitForCondition(timeout: 1.0, condition: { shareLoading.exists }) {
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
        let virtualDisplaySidebar = smokeElement(app, identifier: "sidebar_virtual_display")
        let detail = smokeElement(app, identifier: "detail_virtual_display")
        assertElementsExist([("sidebar_virtual_display", virtualDisplaySidebar)], timeout: 1.2)
        virtualDisplaySidebar.tap()
        assertElementsExist([("detail_virtual_display", detail)], timeout: 1.2)
        return detail
    }

    @MainActor
    private func openVirtualDisplayEditForm(
        in app: XCUIApplication,
        detail: XCUIElement,
        openEditButton: XCUIElement
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
        let formElements: [SmokeNamedElement] = [
            ("edit_virtual_display_form", form),
            ("virtual_display_edit_mode_hidpi_toggle", toggle),
            ("virtual_display_edit_save_only_button", saveOnlyButton),
            ("virtual_display_edit_save_and_rebuild_button", saveAndRebuildButton),
            ("virtual_display_edit_cancel_button", cancelButton)
        ]
        assertAllExist(
            app,
            identifiers: ["detail_virtual_display", "virtual_display_open_edit_test_button"],
            timeout: 1.2
        )
        XCTAssertTrue(detail.exists, "Virtual display detail is unavailable.")
        tapByCoordinate(
            openEditButton,
            timeout: 1,
            requireExistenceCheck: false
        )
        if waitForIdentifierByPolling(app, identifier: "edit_virtual_display_form", timeout: 0.9) {
            assertElementsExist(formElements, timeout: 0.6)
        } else {
            tapByCoordinate(
                openEditButton,
                timeout: 0.6,
                requireExistenceCheck: false
            )
            assertElementsExist(formElements, timeout: 1.5)
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
        detail: XCUIElement,
        openEditButton: XCUIElement
    ) -> (
        form: XCUIElement,
        toggle: XCUIElement,
        saveOnlyButton: XCUIElement,
        saveAndRebuildButton: XCUIElement,
        cancelButton: XCUIElement,
        value: Bool
    ) {
        let state = openVirtualDisplayEditForm(
            in: app,
            detail: detail,
            openEditButton: openEditButton
        )
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
