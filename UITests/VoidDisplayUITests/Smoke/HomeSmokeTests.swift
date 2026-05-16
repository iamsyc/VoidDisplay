import XCTest

final class HomeSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeNavigationSmoke_baseline() throws {
        let app = launchAppForSmoke(scenario: .baseline)

        assertAllExist(
            app,
            identifiers: [
                "sidebar_home",
                "sidebar_displays",
                "sidebar_virtual_display",
                "sidebar_screen_preview",
                "sidebar_screen_sharing",
                "sidebar_diagnostics",
                "detail_home",
                "displays_shell",
                "displays_surface_list",
                "display_surface_row"
            ],
            timeout: 6
        )

        tapIdentifier(app, identifier: "sidebar_displays")
        assertAllExist(app, identifiers: ["detail_displays", "system_displays_list"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_virtual_display")
        assertAllExist(app, identifiers: ["detail_virtual_display", "virtual_display_add_button"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_screen_preview")
        assertAllExist(app, identifiers: ["detail_screen_preview"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_screen_sharing")
        assertAllExist(app, identifiers: ["detail_screen_sharing"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_diagnostics")
        assertAllExist(app, identifiers: ["detail_diagnostics"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_home")
        assertAllExist(app, identifiers: ["detail_home", "display_surface_row"], timeout: 1.5)
    }

    @MainActor
    func testDisplaysSurfaceConvergenceSmoke_baseline() throws {
        let app = launchAppForSmoke(scenario: .baseline)

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "displays_surface_list",
                "display_surface_row",
                "displays_compact_status_line",
                "displays_virtual_display_status",
                "displays_preview_status",
                "displays_lan_web_view_status",
                "displays_viewer_count",
                "displays_technical_details",
                "displays_action_open_preview",
                "displays_action_open_lan_web_view"
            ],
            timeout: 6
        )

        assertDisplaysRowsFitDefaultViewport(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["displays_surface_kind_value"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["displays_resolution_status"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["displays_issue_status"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["displays_action_open_diagnostics"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["displays_action_stop_web_service"].exists)

        tapIdentifier(app, identifier: "displays_action_open_preview")
        assertAllExist(app, identifiers: ["detail_screen_preview"], timeout: 1.5)

        openHomeOverview(in: app)
        tapIdentifier(app, identifier: "displays_action_open_lan_web_view")
        assertAllExist(app, identifiers: ["detail_lan_web_view"], timeout: 1.5)
    }

    @MainActor
    func testDiagnosticsNavigationSmoke_baseline() throws {
        let app = launchAppForSmoke(scenario: .baseline)

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
    private func openHomeOverview(in app: XCUIApplication) {
        if smokeElement(app, identifier: "displays_overview_toolbar_button").exists {
            tapIdentifier(app, identifier: "displays_overview_toolbar_button")
        } else {
            tapIdentifier(app, identifier: "sidebar_home")
        }
        assertAllExist(app, identifiers: ["detail_home", "display_surface_row"], timeout: 1.5)
    }

    @MainActor
    private func assertDisplaysRowsFitDefaultViewport(in app: XCUIApplication) {
        let list = assertExists(app, identifier: "displays_list", timeout: 1.5)
        let rows = app.descendants(matching: .any)
            .matching(identifier: "display_surface_row")
            .allElementsBoundByIndex
            .filter(\.exists)
        XCTAssertFalse(rows.isEmpty, "Displays overview should show at least one display row.")

        let visibleRows = Array(rows.prefix(min(rows.count, 3)))
        for (index, row) in visibleRows.enumerated() {
            assertDisplayRowIsComplete(row, visibleBounds: list.frame, rowIndex: index)
        }
    }

    @MainActor
    private func assertDisplayRowIsComplete(
        _ row: XCUIElement,
        visibleBounds: CGRect,
        rowIndex: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            row.frame.minY,
            visibleBounds.minY - 1,
            "Display row \(rowIndex) should start inside the visible list.",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            row.frame.maxY,
            visibleBounds.maxY + 1,
            "Display row \(rowIndex) should be fully visible in the default window.",
            file: file,
            line: line
        )

        let rowText = displayRowText(row)
        XCTAssertFalse(rowText.isEmpty, "Display row \(rowIndex) should expose identity text.", file: file, line: line)
        XCTAssertNotNil(
            rowText.range(of: #"\d+\s*[×xX]\s*\d+"#, options: .regularExpression),
            "Display row \(rowIndex) should expose resolution without opening details. text=\(rowText)",
            file: file,
            line: line
        )

        assertRowContains(row, identifier: "displays_compact_status_line", rowIndex: rowIndex, file: file, line: line)
        assertRowContains(row, identifier: "displays_preview_status", rowIndex: rowIndex, file: file, line: line)
        assertRowContains(row, identifier: "displays_lan_web_view_status", rowIndex: rowIndex, file: file, line: line)
        assertRowContains(row, identifier: "displays_viewer_count", rowIndex: rowIndex, file: file, line: line)
        assertRowContainsAny(
            row,
            identifiers: ["displays_action_open_preview", "displays_action_stop_preview"],
            rowIndex: rowIndex,
            file: file,
            line: line
        )
        assertRowContainsAny(
            row,
            identifiers: ["displays_action_open_lan_web_view", "displays_action_stop_lan_web_view"],
            rowIndex: rowIndex,
            file: file,
            line: line
        )
    }

    @MainActor
    private func displayRowText(_ row: XCUIElement) -> String {
        var parts = [accessibilityText(for: row)]
        parts.append(contentsOf: row.descendants(matching: .staticText)
            .allElementsBoundByIndex
            .map(accessibilityText(for:)))
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @MainActor
    private func assertRowContains(
        _ row: XCUIElement,
        identifier: String,
        rowIndex: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            row.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists,
            "Display row \(rowIndex) is missing \(identifier).",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertRowContainsAny(
        _ row: XCUIElement,
        identifiers: [String],
        rowIndex: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hasMatch = identifiers.contains { identifier in
            row.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
        }
        XCTAssertTrue(
            hasMatch,
            "Display row \(rowIndex) is missing one of: \(identifiers.joined(separator: ", ")).",
            file: file,
            line: line
        )
    }

    @MainActor
    private func accessibilityText(for element: XCUIElement) -> String {
        let labelText = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !labelText.isEmpty {
            return labelText
        }

        if let valueText = (element.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !valueText.isEmpty {
            return valueText
        }

        return ""
    }
}
