import XCTest

final class DiagnosticsSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDiagnosticsEvidenceJourney() throws {
        let app = launchAppForSmoke(scenario: "diagnostics_transaction_timeline")

        let scrollView = try performSmokeStep("Open recovered warning evidence") {
            try expandDiagnosticsRecoveredWarningEvidence(app)
        }
        try performSmokeStep("Inspect recent events and transaction timeline") {
            try assertDiagnosticsRecentEventsAndTransactionTimeline(app, scrollView: scrollView)
        }
    }

    @MainActor
    private func expandDiagnosticsRecoveredWarningEvidence(
        _ app: XCUIApplication
    ) throws -> XCUIElement {
        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)

        assertExists(
            app,
            identifier: "diagnostics_health_status_title",
            timeout: 6
        )

        let scrollView = try expandDiagnosticsTechnicalInformation(app)
        let warningTag = app.staticTexts
            .matching(identifier: "diagnostics_event_severity_warning")
            .firstMatch
        for _ in 0..<8 where warningTag.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(
            waitForExistenceIfNeeded(warningTag, timeout: 5),
            "Recovered warning scenario did not inject warning evidence."
        )
        XCTAssertTrue(warningTag.isHittable)
        return scrollView
    }

    @MainActor
    private func assertDiagnosticsRecentEventsAndTransactionTimeline(
        _ app: XCUIApplication,
        scrollView: XCUIElement
    ) throws {
        let severityTag = app.staticTexts
            .matching(identifier: "diagnostics_event_severity_info")
            .firstMatch
        for _ in 0..<8 where severityTag.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        assertExists(
            app,
            identifier: "diagnostics_recent_events",
            timeout: 5
        )
        XCTAssertTrue(waitForExistenceIfNeeded(severityTag, timeout: 5))
        XCTAssertTrue(severityTag.isHittable)
        XCTAssertFalse((severityTag.value as? String ?? "").isEmpty)

        let transactionDetails = app.descendants(matching: .any)
            .matching(identifier: "diagnostics_transaction_details")
            .firstMatch
        for _ in 0..<10 where transactionDetails.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(waitForExistenceIfNeeded(transactionDetails, timeout: 5))
        XCTAssertTrue(transactionDetails.isHittable)
        transactionDetails.click()

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

        XCTAssertTrue(waitForExistenceIfNeeded(phase, timeout: 5))
        XCTAssertTrue(waitForExistenceIfNeeded(transactionID, timeout: 5))
        XCTAssertFalse((transactionID.value as? String ?? "").isEmpty)

        let phases = phaseQuery.allElementsBoundByIndex
        let timestamps = timestampQuery.allElementsBoundByIndex
        let eventIDs = eventIDQuery.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(phases.count, 2)
        XCTAssertGreaterThanOrEqual(timestamps.count, 2)
        XCTAssertGreaterThanOrEqual(eventIDs.count, 2)
        let phaseValues = phases.prefix(2).map { $0.value as? String ?? "" }
        XCTAssertTrue(
            phaseValues.allSatisfy { $0.isEmpty == false },
            "Timeline phase labels are empty: \(phaseValues)"
        )
        XCTAssertLessThan(phases[0].frame.minY, phases[1].frame.minY)
        for timestamp in timestamps.prefix(2) {
            XCTAssertFalse((timestamp.value as? String ?? "").isEmpty)
        }
        for eventID in eventIDs.prefix(2) {
            XCTAssertFalse((eventID.value as? String ?? "").isEmpty)
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Diagnostics transaction timeline"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func assertDiagnosticsActionsRemainVisibleAtNarrowWindowSize(_ app: XCUIApplication) throws {
        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)
        let reproductionField = smokeElement(app, identifier: "support_bundle_reproduction_field")
        let expectedField = smokeElement(app, identifier: "support_bundle_expected_field")
        XCTAssertTrue(
            waitForCondition(timeout: 6) {
                reproductionField.exists &&
                    expectedField.exists &&
                    reproductionField.frame.maxY < expectedField.frame.minY
            },
            "Diagnostics fields did not settle into narrow-window vertical order."
        )
        _ = try expandDiagnosticsTechnicalInformation(app)

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
        let app = launchAppForSmoke()

        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)
        assertDiagnosticsBaseLayout(app)
        let window = app.windows.firstMatch
        resizeWindow(window, to: CGSize(width: 760, height: 640))
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
        let validationIsVisible = {
            window.frame.contains(validation.frame) && happenedField.isHittable
        }
        XCTAssertTrue(
            waitForCondition(timeout: 3, validationIsVisible),
            "Validation feedback did not settle into the visible window."
        )
        XCTAssertTrue(window.frame.contains(validation.frame))
        XCTAssertTrue(happenedField.isHittable)
        let focusedControl = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(focusedControl, timeout: 2))
        XCTAssertEqual(focusedControl.identifier, "support_bundle_happened_field")

        for _ in 0..<5 where exportButton.isHittable == false {
            scrollView.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(exportButton.isHittable)

        exportButton.click()

        XCTAssertTrue(waitForExistenceIfNeeded(validation, timeout: 3))
        XCTAssertTrue(
            waitForCondition(timeout: 3, validationIsVisible),
            "Repeated validation feedback did not settle into the visible window."
        )
        XCTAssertTrue(window.frame.contains(validation.frame))
        let refocusedControl = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(refocusedControl, timeout: 2))
        XCTAssertEqual(refocusedControl.identifier, "support_bundle_happened_field")

        try performSmokeStep("Check diagnostic actions at narrow width") {
            try assertDiagnosticsActionsRemainVisibleAtNarrowWindowSize(app)
        }
    }

    @MainActor
    private func assertDiagnosticsBaseLayout(_ app: XCUIApplication) {
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
        assertHomePageActionsAreAbsent(app)

        let healthPanel = smokeElement(app, identifier: "diagnostics_health_summary_panel")
        let draftPanel = smokeElement(app, identifier: "support_bundle_draft_panel")
        let technicalDisclosure = smokeElement(app, identifier: "diagnostics_technical_disclosure")
        let reproductionField = smokeElement(app, identifier: "support_bundle_reproduction_field")
        let expectedField = smokeElement(app, identifier: "support_bundle_expected_field")
        XCTAssertTrue(
            waitForCondition(timeout: 6) {
                healthPanel.frame.minY < draftPanel.frame.minY &&
                    draftPanel.frame.minY < technicalDisclosure.frame.minY &&
                    abs(reproductionField.frame.minY - expectedField.frame.minY) <= 2
            },
            "Diagnostics layout did not settle after navigation."
        )
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
    private func expandDiagnosticsTechnicalInformation(
        _ app: XCUIApplication
    ) throws -> XCUIElement {
        let disclosure = app.descendants(matching: .disclosureTriangle)
            .matching(identifier: "diagnostics_technical_disclosure")
            .firstMatch
        XCTAssertTrue(
            waitForExistenceIfNeeded(disclosure, timeout: 3),
            "Missing diagnostics technical information disclosure."
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
        let expandedContent = smokeElement(
            app,
            identifier: "diagnostics_open_data_directory_button"
        )
        if expandedContent.exists == false {
            let indicatorOffset = min(24, disclosure.frame.width / 2)
            disclosure.coordinate(
                withNormalizedOffset: CGVector(
                    dx: indicatorOffset / disclosure.frame.width,
                    dy: 0.5
                )
            ).click()
        }
        XCTAssertTrue(
            waitForExistenceIfNeeded(expandedContent, timeout: 5),
            "Diagnostics technical information did not finish expanding."
        )
        return scrollView
    }
}
