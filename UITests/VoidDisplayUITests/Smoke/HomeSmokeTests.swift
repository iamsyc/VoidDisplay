import XCTest

final class HomeSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeCoreJourney() throws {
        let app = launchAppForSmoke(advanceFocus: true)

        assertFirstFocusIsVisible(app)

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
        XCTAssertTrue(waitForExistenceIfNeeded(sidebar, timeout: 2))
        XCTAssertEqual(sidebar.children(matching: .outlineRow).count, 2)

        XCTAssertFalse(app.descendants(matching: .any)["sidebar_displays"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_virtual_display"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_screen_preview"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_screen_sharing"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["home_virtual_display_title"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["home_header_screen_recording_permission_status"].exists)

        tapIdentifier(app, identifier: "sidebar_diagnostics")
        assertExists(app, identifier: "detail_diagnostics", timeout: 3)
        assertHomePageActionsAreAbsent(app)

        tapIdentifier(app, identifier: "sidebar_home")
        assertAllExist(app, identifiers: ["detail_home", "home_virtual_display_list_row"], timeout: 1.5)
        assertHomePageActionsAreInToolbar(app)

        performSmokeStep("Display list and sharing controls") { assertVirtualDisplayListSurface(app) }
        performSmokeStep("Popover dismissal and sidebar focus") { assertSharingPopoverDismissalJourney(app) }
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 760, height: 640))
        assertListActionsRemainVisibleAcrossNarrowWindowSizes(app)
    }

    @MainActor
    func testScreenRecordingRecoveryActionsFitAtNarrowWindowSize() throws {
        let app = launchAppForSmoke(scenario: "permission_denied")
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))
        assertAllExist(
            app,
            identifiers: [
                "home_header_screen_recording_permission_status",
                "home_open_privacy_settings_button",
                "home_check_screen_recording_permission_button"
            ],
            timeout: 6
        )
        XCTAssertGreaterThan(window.frame.width, 1000, "Permission recovery must be covered at the default wide size.")

        resizeWindow(window, to: CGSize(width: 600, height: 640))

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
    func testDisplayRescanJourney() throws {
        let app = launchAppForSmoke(
            scenario: "display_catalog_loading_missing_managed_display"
        )

        performSmokeStep("Inline rescan preserves control geometry") { assertDisplayRescanControlsRemainStableWhileScanning(app) }
        performSmokeStep("Toolbar rescan reports completion") { assertDisplayRescanExplainsPurposeAndReportsResult(app) }
        try performSmokeStep("Rescan feedback remains visible after scrolling") { try assertDisplayRescanFeedbackRemainsVisibleAfterScrolling(app) }
    }

    @MainActor
    private func assertDisplayRescanExplainsPurposeAndReportsResult(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))
        resizeWindow(window, to: CGSize(width: 600, height: 640))
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
    private func assertDisplayRescanControlsRemainStableWhileScanning(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))
        resizeWindow(window, to: CGSize(width: 1180, height: 720))
        let toolbarRescanIdentifier = "home_rescan_displays_button"
        let inlineRescanIdentifier = "home_virtual_display_rescan_button"
        let toolbarRescanButton = assertExists(
            app,
            identifier: toolbarRescanIdentifier,
            timeout: 6
        )
        let initialInlineRescanButton = assertExists(
            app,
            identifier: inlineRescanIdentifier,
            timeout: 7
        )
        let scanningLabels = ["Detecting Displays…", "正在检测显示器…"]

        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                !initialInlineRescanButton.isEnabled &&
                    scanningLabels.contains(initialInlineRescanButton.value as? String ?? "")
            },
            "The inline rescan control did not expose the initial scanning state."
        )
        let initialInlineScanningFrame = initialInlineRescanButton.frame

        XCTAssertTrue(
            waitForCondition(timeout: 6) { toolbarRescanButton.isEnabled },
            "The toolbar rescan control did not become ready after the initial display load."
        )
        // The first display's scanning button disappears when its catalog entry loads.
        // Continue with the second fixture display, which remains missing from the catalog.
        let missingDisplayRow = app.descendants(matching: .any)
            .matching(identifier: "home_virtual_display_list_row")
            .element(boundBy: 1)
        let inlineRescanButton = missingDisplayRow.descendants(matching: .any)
            .matching(identifier: inlineRescanIdentifier)
            .firstMatch
        XCTAssertTrue(
            waitForCondition(timeout: 6) { inlineRescanButton.exists && inlineRescanButton.isEnabled },
            "The missing display's rescan control did not become ready after the initial display load."
        )
        XCTAssertTrue(
            waitForHittable(inlineRescanButton),
            "The inline rescan control was not ready for interaction."
        )
        let idleToolbarFrame = toolbarRescanButton.frame
        let idleInlineFrame = inlineRescanButton.frame
        XCTAssertTrue(
            missingDisplayRow.frame.contains(idleInlineFrame),
            "The inline rescan control must stay within the missing display row."
        )

        XCTAssertEqual(
            initialInlineScanningFrame.minX,
            idleInlineFrame.minX,
            accuracy: 1,
            "The inline rescan control must not move horizontally during the initial scan."
        )
        XCTAssertEqual(
            initialInlineScanningFrame.width,
            idleInlineFrame.width,
            accuracy: 1,
            "The inline rescan control width must remain stable during the initial scan."
        )

        inlineRescanButton.click()

        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                !toolbarRescanButton.isEnabled &&
                    scanningLabels.contains(toolbarRescanButton.value as? String ?? "") &&
                    !inlineRescanButton.isEnabled &&
                    scanningLabels.contains(inlineRescanButton.value as? String ?? "")
            },
            "The rescan controls did not expose their scanning state after the inline action."
        )
        XCTAssertEqual(
            toolbarRescanButton.frame.minX,
            idleToolbarFrame.minX,
            accuracy: 1,
            "The toolbar rescan control must not move horizontally while scanning."
        )
        XCTAssertEqual(
            toolbarRescanButton.frame.width,
            idleToolbarFrame.width,
            accuracy: 1,
            "The toolbar rescan control width must remain stable while scanning."
        )
        XCTAssertEqual(
            inlineRescanButton.frame.minX,
            idleInlineFrame.minX,
            accuracy: 1,
            "The inline rescan control must not move horizontally while scanning."
        )
        XCTAssertEqual(
            inlineRescanButton.frame.width,
            idleInlineFrame.width,
            accuracy: 1,
            "The inline rescan control width must remain stable while scanning."
        )

        XCTAssertTrue(
            waitForCondition(timeout: 6) {
                toolbarRescanButton.isEnabled &&
                    inlineRescanButton.isEnabled
            },
            "The rescan controls did not become ready after display detection completed."
        )
        XCTAssertEqual(
            toolbarRescanButton.frame.minX,
            idleToolbarFrame.minX,
            accuracy: 1,
            "The toolbar rescan control must return without horizontal movement after scanning."
        )
        XCTAssertEqual(
            toolbarRescanButton.frame.width,
            idleToolbarFrame.width,
            accuracy: 1,
            "The toolbar rescan control width must remain stable after scanning."
        )
    }

    @MainActor
    private func assertDisplayRescanFeedbackRemainsVisibleAfterScrolling(_ app: XCUIApplication) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))
        resizeWindow(window, to: CGSize(width: 600, height: 300))
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
    private func assertVirtualDisplayListSurface(_ app: XCUIApplication) {
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
        tapIdentifier(app, identifier: "home_sharing_settings_popover_button")
        XCTAssertTrue(
            waitForAbsence(smokeElement(app, identifier: "home_sharing_settings_panel"), timeout: 1)
        )
    }

    @MainActor
    private func assertListActionsRemainVisibleAcrossNarrowWindowSizes(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))
        assertSelectedSidebarHasKeyboardFocus(app)
        assertHomePageActionsAreInToolbar(app)

        let minimumWidthIdentifiers = [
            "home_sharing_settings_popover_button",
            "home_rescan_displays_button",
            "virtual_display_toggle_button",
            "home_virtual_display_preview_toggle",
            "home_virtual_display_web_view_toggle",
            "virtual_display_edit_button",
            "home_virtual_display_more_button"
        ]
        for identifier in ["home_add_virtual_display_button"] + minimumWidthIdentifiers {
            let element = assertExists(app, identifier: identifier, timeout: 6)
            XCTAssertTrue(waitForHittable(element), "Element is not hittable: \(identifier)")
            XCTAssertTrue(window.frame.contains(element.frame), "Element is outside window: \(identifier)")
        }

        resizeWindow(window, to: CGSize(width: 600, height: 640))

        for identifier in minimumWidthIdentifiers {
            let element = assertExists(app, identifier: identifier, timeout: 6)
            XCTAssertTrue(waitForHittable(element), "Element is not hittable: \(identifier)")
            XCTAssertTrue(window.frame.contains(element.frame), "Element is outside window: \(identifier)")
        }
    }

    @MainActor
    private func assertFirstFocusIsVisible(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))

        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(focused, timeout: 2))
        XCTAssertTrue(window.frame.intersects(focused.frame))
        XCTAssertGreaterThan(focused.frame.width, 1)
        XCTAssertGreaterThan(focused.frame.height, 1)
    }

    @MainActor
    private func assertSharingPopoverDismissalJourney(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))
        let toolbar = app.toolbars.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(toolbar, timeout: 2))
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
            waitForExistenceIfNeeded(systemSidebarToggle, timeout: 2),
            "NavigationSplitView must expose its system sidebar toggle."
        )
        XCTAssertTrue(systemSidebarToggle.isHittable)

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
            waitForExistenceIfNeeded(focusedPopoverControl, timeout: 1),
            "Sharing settings should move focus into the presented popover."
        )

        toolbar.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()

        XCTAssertTrue(
            waitForAbsence(sharingSettingsPanel, timeout: 1),
            "Clicking the toolbar background should dismiss Sharing Settings."
        )
        assertSelectedSidebarHasKeyboardFocus(app)

        let sidebar = app.outlines.matching(identifier: "home_sidebar").firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(sidebar, timeout: 1))

        systemSidebarToggle.click()
        XCTAssertTrue(
            waitForAbsence(sidebar, timeout: 1),
            "The system sidebar toggle should still collapse the sidebar after dismissing the popover."
        )

        tapIdentifier(app, identifier: "home_sharing_settings_popover_button")
        let collapsedSidebarPanel = assertExists(
            app,
            identifier: "home_sharing_settings_panel",
            timeout: 2
        )
        toolbar.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        XCTAssertTrue(
            waitForAbsence(collapsedSidebarPanel, timeout: 1),
            "Clicking the toolbar background should dismiss Sharing Settings with the sidebar collapsed."
        )
        XCTAssertTrue(
            waitForAbsence(sidebar, timeout: 1),
            "Dismissing Sharing Settings must not restore a collapsed sidebar."
        )

        systemSidebarToggle.click()
        XCTAssertTrue(
            waitForExistenceIfNeeded(sidebar, timeout: 2),
            "The system sidebar toggle should restore the sidebar."
        )
    }
}
