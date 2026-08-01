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
                "home_rescan_displays_button",
                "home_virtual_display_list_row"
            ],
            timeout: 6
        )
        assertHomePageActionsAreInToolbar(app)

        let sidebar = app.outlines.matching(identifier: "home_sidebar").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        XCTAssertEqual(sidebar.children(matching: .outlineRow).count, 2)

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
                "home_open_privacy_settings_button",
                "home_check_screen_recording_permission_button"
            ],
            timeout: 6
        )
    }

    @MainActor
    func testScreenRecordingRecoveryActionsFitAtNarrowWindowSize() throws {
        let app = launchAppForSmoke(
            windowSize: (600, 640),
            scenario: "permission_denied"
        )
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))

        for identifier in [
            "home_open_privacy_settings_button",
            "home_check_screen_recording_permission_button"
        ] {
            let button = assertExists(app, identifier: identifier, timeout: 6)
            XCTAssertTrue(
                window.frame.contains(button.frame),
                "Permission recovery action extends outside the narrow Home window: \(identifier)"
            )
            XCTAssertTrue(waitForHittable(button), "Permission recovery action is not usable: \(identifier)")
        }
    }

    @MainActor
    func testDisplayRescanExplainsPurposeAndReportsResult() throws {
        let app = launchAppForSmoke(
            windowSize: (600, 640),
            scenario: "display_catalog_loading"
        )
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))
        let rescanButton = assertExists(
            app,
            identifier: "home_rescan_displays_button",
            timeout: 6
        )
        let firstDisplayRow = assertExists(
            app,
            identifier: "home_virtual_display_list_row",
            timeout: 6
        )
        let rowOriginBeforeRescan = firstDisplayRow.frame.minY

        XCTAssertTrue(
            ["Rescan Displays", "重新检测显示器"].contains(rescanButton.label),
            "Unexpected rescan label: \(rescanButton.label)"
        )
        let initialLoadDeadline = Date().addingTimeInterval(6)
        while !rescanButton.isEnabled, Date() < initialLoadDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            rescanButton.isEnabled,
            "Rescan button did not become ready after the initial display load."
        )
        rescanButton.click()

        let scanningLabels = ["Detecting Displays…", "正在检测显示器…"]
        let scanningDeadline = Date().addingTimeInterval(1)
        while !scanningLabels.contains(rescanButton.value as? String ?? ""), Date() < scanningDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            scanningLabels.contains(rescanButton.value as? String ?? ""),
            "Rescan button did not expose its scanning state after the click."
        )
        let detectionStatus = assertExists(
            app,
            identifier: "home_display_detection_status",
            timeout: 3
        )
        XCTAssertTrue(
            window.frame.contains(detectionStatus.frame),
            "Display detection feedback is outside the minimum-width window."
        )
        XCTAssertFalse(
            detectionStatus.frame.intersects(firstDisplayRow.frame),
            "Display detection feedback must not cover the display list."
        )
        XCTAssertEqual(
            firstDisplayRow.frame.minY,
            rowOriginBeforeRescan,
            accuracy: 1,
            "Display detection feedback must not move the display list."
        )

        let completionMessage = detectionStatus.staticTexts.firstMatch
        let completionDeadline = Date().addingTimeInterval(5)
        var completionValue = ""
        while Date() < completionDeadline {
            completionValue = completionMessage.value as? String ?? ""
            if completionValue == "Display list is up to date."
                || completionValue == "显示器列表已是最新。"
                || completionValue.hasPrefix("Detected Displays:")
                || completionValue.hasPrefix("检测到的显示器：")
            {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            completionValue == "Display list is up to date."
                || completionValue == "显示器列表已是最新。"
                || completionValue.hasPrefix("Detected Displays:")
                || completionValue.hasPrefix("检测到的显示器："),
            "Display detection did not report its terminal result. Value: \(completionValue)"
        )
        XCTAssertTrue(
            rescanButton.isEnabled,
            "Rescan button did not become ready after reporting its terminal result."
        )
        XCTAssertTrue(
            detectionStatus.exists,
            "Terminal display detection feedback disappeared immediately."
        )
        XCTAssertEqual(
            firstDisplayRow.frame.minY,
            rowOriginBeforeRescan,
            accuracy: 1,
            "Terminal display detection feedback must not move the display list."
        )
    }

    @MainActor
    func testDisplayRescanButtonDoesNotMoveWhileScanning() throws {
        let app = launchAppForSmoke(
            windowSize: (1180, 720),
            scenario: "display_catalog_loading"
        )
        let rescanButton = assertExists(
            app,
            identifier: "home_rescan_displays_button",
            timeout: 6
        )
        let scanningLabels = ["Detecting Displays…", "正在检测显示器…"]
        let initialLoadDeadline = Date().addingTimeInterval(6)
        while !rescanButton.isEnabled, Date() < initialLoadDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            rescanButton.isEnabled,
            "Rescan button did not become ready after the initial display load."
        )
        let idleFrame = rescanButton.frame

        rescanButton.click()
        let scanningDeadline = Date().addingTimeInterval(1)
        while !scanningLabels.contains(rescanButton.value as? String ?? ""), Date() < scanningDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            scanningLabels.contains(rescanButton.value as? String ?? ""),
            "Rescan button did not expose its scanning state."
        )
        let scanningFrame = rescanButton.frame

        XCTAssertEqual(
            scanningFrame.minX,
            idleFrame.minX,
            accuracy: 1,
            "Rescan button must not move horizontally while scanning."
        )
        XCTAssertEqual(
            scanningFrame.width,
            idleFrame.width,
            accuracy: 1,
            "Rescan button width must remain stable while scanning."
        )

        let completedDeadline = Date().addingTimeInterval(5)
        while !rescanButton.isEnabled, Date() < completedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            rescanButton.isEnabled,
            "Rescan button did not become ready after display detection completed."
        )
        let completedFrame = rescanButton.frame
        XCTAssertEqual(
            completedFrame.minX,
            idleFrame.minX,
            accuracy: 1,
            "Rescan button must return without horizontal movement after scanning."
        )
        XCTAssertEqual(
            completedFrame.width,
            idleFrame.width,
            accuracy: 1,
            "Rescan button width must remain stable after scanning."
        )
    }

    @MainActor
    func testDisplayRescanFeedbackRemainsVisibleAfterScrolling() throws {
        let app = launchAppForSmoke(
            windowSize: (600, 300),
            scenario: "display_catalog_loading"
        )
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))
        let rescanButton = assertExists(
            app,
            identifier: "home_rescan_displays_button",
            timeout: 6
        )
        let summary = assertExists(
            app,
            identifier: "home_summary_status_strip",
            timeout: 6
        )
        let scrollView = try XCTUnwrap(
            app.scrollViews.allElementsBoundByIndex.max { lhs, rhs in
                lhs.frame.width < rhs.frame.width
            }
        )
        let initialLoadDeadline = Date().addingTimeInterval(6)
        while !rescanButton.isEnabled, Date() < initialLoadDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(rescanButton.isEnabled)

        for _ in 0..<6 where summary.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertFalse(
            summary.isHittable,
            "Test precondition failed: the Home content did not scroll away from its top."
        )

        rescanButton.click()

        let detectionStatus = assertExists(
            app,
            identifier: "home_display_detection_status",
            timeout: 3
        )
        XCTAssertTrue(
            window.frame.contains(detectionStatus.frame),
            "Display detection feedback must remain in the visible viewport after scrolling."
        )
    }

    @MainActor
    func testInlineRescanControlRemainsStableWhileScanning() throws {
        let app = launchAppForSmoke(
            windowSize: (1180, 720),
            scenario: "display_catalog_loading"
        )
        let inlineRescanIdentifier = "home_virtual_display_rescan_button"
        var inlineRescanButton = assertExists(
            app,
            identifier: inlineRescanIdentifier,
            timeout: 7
        )

        let initialLoadDeadline = Date.now.addingTimeInterval(6)
        while !(inlineRescanButton.exists && inlineRescanButton.isEnabled),
              Date.now < initialLoadDeadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
            inlineRescanButton = smokeElement(app, identifier: inlineRescanIdentifier)
        }
        XCTAssertTrue(
            inlineRescanButton.exists && inlineRescanButton.isEnabled,
            "The inline rescan control did not become ready after the initial display load."
        )
        XCTAssertTrue(
            waitForHittable(inlineRescanButton),
            "The inline rescan control was not ready for interaction."
        )
        let idleFrame = inlineRescanButton.frame

        inlineRescanButton.click()

        let scanningLabels = ["Detecting Displays…", "正在检测显示器…"]
        let scanningDeadline = Date.now.addingTimeInterval(2)
        var scanningInlineRescanButton = smokeElement(app, identifier: inlineRescanIdentifier)
        while Date.now < scanningDeadline {
            let scanningValue = scanningInlineRescanButton.value as? String ?? ""
            if scanningInlineRescanButton.exists,
               !scanningInlineRescanButton.isEnabled,
               scanningLabels.contains(scanningValue) {
                break
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
            scanningInlineRescanButton = smokeElement(app, identifier: inlineRescanIdentifier)
        }
        XCTAssertTrue(
            scanningInlineRescanButton.exists,
            "The inline rescan control must remain mounted while scanning."
        )
        XCTAssertFalse(
            scanningInlineRescanButton.isEnabled,
            "The inline rescan control did not enter the scanning state."
        )
        XCTAssertTrue(
            scanningLabels.contains(scanningInlineRescanButton.value as? String ?? ""),
            "The inline rescan control did not expose its scanning state."
        )
        XCTAssertEqual(
            scanningInlineRescanButton.frame.minX,
            idleFrame.minX,
            accuracy: 1,
            "The inline rescan control must not move horizontally while scanning."
        )
        XCTAssertEqual(
            scanningInlineRescanButton.frame.width,
            idleFrame.width,
            accuracy: 1,
            "The inline rescan control width must remain stable while scanning."
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
            "home_rescan_displays_button",
            "virtual_display_toggle_button",
            "home_virtual_display_preview_toggle",
            "home_virtual_display_web_view_toggle",
            "virtual_display_edit_button",
            "home_virtual_display_more_button"
        ] {
            let element = assertExists(app, identifier: identifier, timeout: 6)
            XCTAssertTrue(waitForHittable(element), "Element is not hittable: \(identifier)")
            XCTAssertTrue(window.frame.contains(element.frame), "Element is outside window: \(identifier)")
        }
    }

    @MainActor
    func testMinimumWindowWidthPreservesHomeRows() throws {
        let app = launchAppForSmoke(windowSize: (600, 640))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))

        for identifier in [
            "home_sharing_settings_popover_button",
            "home_rescan_displays_button",
            "virtual_display_toggle_button",
            "home_virtual_display_preview_toggle",
            "home_virtual_display_web_view_toggle",
            "virtual_display_edit_button",
            "home_virtual_display_more_button"
        ] {
            let element = assertExists(app, identifier: identifier, timeout: 6)
            XCTAssertTrue(waitForHittable(element), "Element is not hittable: \(identifier)")
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
    func testDiagnosticsRecoveredHistoricalWarningRemainsHealthy() throws {
        let app = launchAppForSmoke(scenario: "diagnostics_recovered_warning")
        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)

        let statusTitle = assertExists(
            app,
            identifier: "diagnostics_health_status_title",
            timeout: 6
        )
        let statusText = statusTitle.value as? String ?? statusTitle.label

        XCTAssertTrue(
            ["Looks Good", "状态正常"].contains(statusText),
            "Recovered historical warning still appears unhealthy: \(statusText)"
        )

        let scrollView = try expandDiagnosticsTechnicalInformation(app)
        let warningTag = app.staticTexts
            .matching(identifier: "diagnostics_event_severity_warning")
            .firstMatch
        for _ in 0..<8 where warningTag.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(
            warningTag.waitForExistence(timeout: 5),
            "Recovered warning scenario did not inject warning evidence."
        )
        XCTAssertTrue(warningTag.isHittable)
    }

    @MainActor
    func testDiagnosticsRecentEventsExposeSeverity() throws {
        let app = launchAppForSmoke()
        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)

        let scrollView = try expandDiagnosticsTechnicalInformation(app)

        let severityTag = app.staticTexts
            .matching(identifier: "diagnostics_event_severity_info")
            .firstMatch
        for _ in 0..<8 {
            guard severityTag.isHittable == false else { break }
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }

        assertExists(
            app,
            identifier: "diagnostics_recent_events",
            timeout: 5
        )
        XCTAssertTrue(severityTag.waitForExistence(timeout: 5))
        XCTAssertTrue(severityTag.isHittable)
        XCTAssertTrue(
            ["Info", "信息"].contains(severityTag.value as? String ?? ""),
            "Unexpected severity text: \(String(describing: severityTag.value))"
        )
    }

    @MainActor
    func testDiagnosticsTransactionTimelineShowsMillisecondsAndEventIDs() throws {
        let app = launchAppForSmoke()
        let toggle = assertExists(
            app,
            identifier: "virtual_display_toggle_button",
            timeout: 6
        )
        toggle.tap()
        XCTAssertTrue(waitForHittable(toggle, timeout: 6))
        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)

        let scrollView = try expandDiagnosticsTechnicalInformation(app)
        let transactionDetails = app.descendants(matching: .any)
            .matching(identifier: "diagnostics_transaction_details")
            .firstMatch
        for _ in 0..<10 where transactionDetails.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(transactionDetails.waitForExistence(timeout: 5))
        XCTAssertTrue(transactionDetails.isHittable)
        transactionDetails.click()
        XCTAssertTrue(
            ["Expanded", "已展开"].contains(transactionDetails.value as? String ?? ""),
            "Details button does not expose its expanded state."
        )

        let phaseQuery = app.descendants(matching: .any)
            .matching(identifier: "diagnostics_transaction_phase")
        let phase = phaseQuery.firstMatch
        for _ in 0..<8 where phase.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -240)
        }
        let timestampQuery = app.descendants(matching: .any)
            .matching(identifier: "diagnostics_event_timestamp_milliseconds")
        let eventIDQuery = app.descendants(matching: .any)
            .matching(identifier: "diagnostics_event_id")
        let transactionID = app.descendants(matching: .any)
            .matching(identifier: "diagnostics_transaction_id")
            .firstMatch

        XCTAssertTrue(phase.waitForExistence(timeout: 5))
        XCTAssertTrue(transactionID.waitForExistence(timeout: 5))
        XCTAssertNotNil(UUID(uuidString: transactionID.value as? String ?? ""))

        let phases = phaseQuery.allElementsBoundByIndex
        let timestamps = timestampQuery.allElementsBoundByIndex
        let eventIDs = eventIDQuery.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(phases.count, 2)
        XCTAssertGreaterThanOrEqual(timestamps.count, 2)
        XCTAssertGreaterThanOrEqual(eventIDs.count, 2)
        XCTAssertTrue(["Preparing", "准备中"].contains(phases[0].value as? String ?? ""))
        XCTAssertTrue(
            ["Persisting configuration", "正在保存配置"].contains(
                phases[1].value as? String ?? ""
            )
        )
        XCTAssertLessThan(phases[0].frame.minY, phases[1].frame.minY)
        for timestamp in timestamps.prefix(2) {
            let timestampText = timestamp.value as? String ?? ""
            XCTAssertNotNil(
                timestampText.range(
                    of: #"\d{1,2}:\d{2}:\d{2}[\.,]\d{3}"#,
                    options: .regularExpression
                ),
                "Timestamp does not include milliseconds: \(timestampText)"
            )
        }
        for eventID in eventIDs.prefix(2) {
            XCTAssertNotNil(UUID(uuidString: eventID.value as? String ?? ""))
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Diagnostics transaction timeline"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
        XCTAssertTrue(
            window.frame.contains(openDirectoryButton.frame),
            "Open directory button \(openDirectoryButton.frame) is outside window \(window.frame)"
        )
    }

    @MainActor
    func testDiagnosticsEmptyExportFocusesVisibleValidation() throws {
        let app = launchAppForSmoke(windowSize: (760, 640))
        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)
        let exportButton = assertExists(app, identifier: "support_bundle_export_button", timeout: 3)
        let scrollView = try XCTUnwrap(
            app.scrollViews.allElementsBoundByIndex.max { lhs, rhs in
                lhs.frame.width < rhs.frame.width
            }
        )
        for _ in 0..<5 where exportButton.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(exportButton.isHittable)

        exportButton.click()

        let validation = assertExists(app, identifier: "support_bundle_validation_message", timeout: 3)
        let happenedField = assertExists(app, identifier: "support_bundle_happened_field", timeout: 3)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.frame.contains(validation.frame))
        XCTAssertTrue(happenedField.isHittable)
        let focusedControl = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        XCTAssertTrue(focusedControl.waitForExistence(timeout: 2))
        XCTAssertEqual(focusedControl.identifier, "support_bundle_happened_field")

        for _ in 0..<5 where exportButton.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(exportButton.isHittable)

        exportButton.click()

        XCTAssertTrue(validation.waitForExistence(timeout: 3))
        XCTAssertTrue(window.frame.contains(validation.frame))
        let refocusedControl = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        XCTAssertTrue(refocusedControl.waitForExistence(timeout: 2))
        XCTAssertEqual(refocusedControl.identifier, "support_bundle_happened_field")
    }

    @MainActor
    func testCreateAndEditSheetsOpenAndCancel() throws {
        let app = launchAppForSmoke()

        tapIdentifier(app, identifier: "home_add_virtual_display_button", timeout: 6)
        assertAllExist(
            app,
            identifiers: ["virtual_display_create_form", "virtual_display_create_cancel_button"],
            timeout: 3
        )
        assertSingleFormLabel(app, english: "Screen Size", chinese: "屏幕尺寸")
        tapIdentifier(app, identifier: "virtual_display_create_custom_serial_toggle")
        assertSingleFormLabel(app, english: "Serial Number", chinese: "序列号")
        tapIdentifier(app, identifier: "virtual_display_create_cancel_button")
        XCTAssertFalse(smokeElement(app, identifier: "virtual_display_create_form").waitForExistence(timeout: 1))

        tapIdentifier(app, identifier: "virtual_display_edit_button", timeout: 3)
        assertAllExist(
            app,
            identifiers: ["edit_virtual_display_form", "virtual_display_edit_cancel_button"],
            timeout: 3
        )
        assertSingleFormLabel(app, english: "Screen Size", chinese: "屏幕尺寸")
        assertSingleFormLabel(app, english: "Serial Number", chinese: "序列号")
        tapIdentifier(app, identifier: "virtual_display_edit_cancel_button")
        XCTAssertFalse(smokeElement(app, identifier: "edit_virtual_display_form").waitForExistence(timeout: 1))
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
    func testDismissingSharingSettingsByClickingToolbarBlankClosesPopover() throws {
        let app = launchAppForSmoke()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))
        let toolbar = app.toolbars.firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 2))
        let systemSidebarToggle = app.buttons
            .matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR label CONTAINS %@",
                    "Sidebar",
                    "边栏"
                )
            )
            .firstMatch
        XCTAssertTrue(
            systemSidebarToggle.waitForExistence(timeout: 2),
            "NavigationSplitView must expose its system sidebar toggle."
        )
        XCTAssertTrue(systemSidebarToggle.isHittable)

        for _ in 0..<3 {
            tapIdentifier(app, identifier: "home_sharing_settings_popover_button")
            let sharingSettingsPanel = assertExists(
                app,
                identifier: "home_sharing_settings_panel",
                timeout: 2
            )
            let focusedPopoverControl = sharingSettingsPanel.descendants(matching: .any)
                .matching(NSPredicate(format: "hasKeyboardFocus == true"))
                .firstMatch
            XCTAssertTrue(
                focusedPopoverControl.waitForExistence(timeout: 1),
                "Sharing settings should move focus into the presented popover."
            )

            toolbar.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()

            XCTAssertFalse(
                sharingSettingsPanel.waitForExistence(timeout: 1),
                "Clicking the toolbar background should dismiss Sharing Settings."
            )
        }

        let sidebar = app.outlines.matching(identifier: "home_sidebar").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 1))

        systemSidebarToggle.click()
        XCTAssertFalse(
            sidebar.waitForExistence(timeout: 1),
            "The system sidebar toggle should still collapse the sidebar after dismissing the popover."
        )

        systemSidebarToggle.click()
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: 2),
            "The system sidebar toggle should restore the sidebar."
        )
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
        let waitingContent = app.descendants(matching: .any)
            .matching(identifier: "capture_preview_waiting_for_identity")
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Preview", "预览"))
            .firstMatch
        XCTAssertTrue(waitingContent.waitForExistence(timeout: 2))
    }

    @MainActor
    func testPreviewActiveWindowUsesDisplayIdentityAndToolbar() throws {
        let app = launchAppForSmoke(scenario: "preview_active")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))

        let picker = assertExists(app, identifier: "capture_preview_scale_mode_picker", timeout: 3)
        let cursorToggle = assertExists(app, identifier: "capture_preview_cursor_toggle", timeout: 3)
        XCTAssertTrue(picker.isHittable)
        XCTAssertTrue(cursorToggle.isHittable)

        let previewContent = app.descendants(matching: .any)
            .matching(identifier: "capture_preview_content")
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    "Studio Display",
                    "2560 × 1440"
                )
            )
            .firstMatch
        XCTAssertTrue(previewContent.waitForExistence(timeout: 3))
        XCTAssertTrue(previewContent.label.contains("Studio Display"))
        XCTAssertTrue(previewContent.label.contains("2560 × 1440"))
        XCTAssertTrue(["Preview", "预览"].contains { previewContent.label.contains($0) })

        let nativeScale = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "1:1"))
            .firstMatch
        XCTAssertTrue(nativeScale.waitForExistence(timeout: 2))
        nativeScale.click()
        XCTAssertEqual(picker.value as? String, "1:1")

        cursorToggle.click()
        XCTAssertEqual((cursorToggle.value as? NSNumber)?.boolValue, true)

        let closeButton = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        closeButton.click()
        XCTAssertFalse(window.waitForExistence(timeout: 3))

        app.activate()
        let englishNewWindowItem = app.menuItems["New Window"]
        let localizedNewWindowItem = app.menuItems["新建窗口"]
        let newWindowItem = englishNewWindowItem.waitForExistence(timeout: 2)
            ? englishNewWindowItem
            : localizedNewWindowItem
        XCTAssertTrue(newWindowItem.waitForExistence(timeout: 2))
        newWindowItem.click()
        assertAllExist(
            app,
            identifiers: ["detail_home", "home_virtual_display_preview_toggle"],
            timeout: 4
        )
        let previewToggle = app.switches
            .matching(identifier: "home_virtual_display_preview_toggle")
            .firstMatch
        XCTAssertEqual((previewToggle.value as? NSNumber)?.boolValue, false)
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
            "home_rescan_displays_button",
            "home_sharing_settings_popover_button",
            "home_add_virtual_display_button"
        ]
    }

    @MainActor
    private func expandDiagnosticsTechnicalInformation(
        _ app: XCUIApplication
    ) throws -> XCUIElement {
        let disclosure = assertExists(
            app,
            identifier: "diagnostics_technical_disclosure",
            timeout: 3
        )
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
        return scrollView
    }

    @MainActor
    private func assertSingleFormLabel(
        _ app: XCUIApplication,
        english: String,
        chinese: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let labels = app.staticTexts.matching(
            NSPredicate(format: "value == %@ OR value == %@", english, chinese)
        )
        XCTAssertEqual(labels.count, 1, "Duplicate form label: \(english)", file: file, line: line)
    }
}
