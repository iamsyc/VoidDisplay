import AppKit
import XCTest

final class MenuBarQuickActionsSmokeTests: XCTestCase {
    private struct MenuBarWindow {
        let id: CGWindowID
        let frame: CGRect
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPanelActions() throws {
        let existingMenuBarWindowIDs = Set(controlCenterMenuBarWindows().map(\.id))
        let app = launchAppForSmoke(
            preferredPort: UITestPortAllocator.randomUnprivilegedPort(),
            scenario: "menu_bar_quick_actions"
        )
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(mainWindow, timeout: 6))
        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitForAbsence(mainWindow, timeout: 2))
        openQuickActionsPanel(app, excluding: existingMenuBarWindowIDs)

        assertAllExist(
            app,
            identifiers: [
                "menu_bar_quick_actions_panel",
                "menu_bar_runtime_summary",
                "menu_bar_open_main_window_button",
                "menu_bar_virtual_display_row",
                "menu_bar_virtual_display_toggle_button"
            ],
            timeout: 6
        )

        let panel = smokeElement(app, identifier: "menu_bar_quick_actions_panel")
        XCTAssertLessThanOrEqual(panel.frame.width, 340)
        XCTAssertLessThanOrEqual(panel.frame.height, 180)

        let summary = smokeElement(app, identifier: "menu_bar_runtime_summary")
        XCTAssertGreaterThan(panel.frame.height, summary.frame.height)

        let rows = app.descendants(matching: .any)
            .matching(identifier: "menu_bar_virtual_display_row")
            .allElementsBoundByIndex
        XCTAssertEqual(rows.count, 2)
        XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY)

        XCTAssertEqual(app.buttons.matching(identifier: "menu_bar_web_view_button").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "menu_bar_copy_access_link_button").count, 0)
        XCTAssertEqual(app.buttons.matching(identifier: "menu_bar_open_preview_button").count, 1)
        XCTAssertTrue(rows[0].buttons["menu_bar_open_preview_button"].isHittable)
        XCTAssertTrue(rows[0].buttons["menu_bar_web_view_button"].isHittable)
        XCTAssertFalse(rows[1].buttons["menu_bar_open_preview_button"].exists)
        XCTAssertFalse(rows[1].buttons["menu_bar_web_view_button"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Real menu bar quick actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        performSmokeStep("Disable and enable a display from the menu bar") {
            let toggleButton = rows[1].buttons["menu_bar_virtual_display_toggle_button"]
            XCTAssertTrue(waitForHittable(toggleButton))
            toggleButton.click()
            XCTAssertTrue(
                waitForToggleState(toggleButton, enabled: false),
                "The virtual display did not reach the disabled state."
            )

            toggleButton.click()
            XCTAssertTrue(
                waitForToggleState(toggleButton, enabled: true),
                "The virtual display did not return to the enabled state."
            )
            XCTAssertTrue(
                waitForCondition(timeout: 8) {
                    rows[1].buttons["menu_bar_open_preview_button"].exists
                        && rows[1].buttons["menu_bar_web_view_button"].exists
                },
                "Runtime actions did not appear after the virtual display started."
            )
        }

        let previewButton = rows[0].buttons["menu_bar_open_preview_button"]
        XCTAssertTrue(waitForHittable(previewButton))
        previewButton.click()

        let previewContent = assertExists(app, identifier: "capture_preview_content", timeout: 6)
        XCTAssertTrue(previewContent.exists)

        openQuickActionsPanel(app, excluding: existingMenuBarWindowIDs)
        tapIdentifier(app, identifier: "menu_bar_open_main_window_button")
        assertExists(app, identifier: "detail_home", timeout: 4)
        XCTAssertFalse(smokeElement(app, identifier: "capture_preview_waiting_for_identity").exists)

        let homeRows = app.descendants(matching: .any)
            .matching(identifier: "home_virtual_display_list_row")
        XCTAssertEqual(homeRows.count, 2)
        let editedRow = homeRows.element(boundBy: 1)

        for enabled in [false, true] {
            performSmokeStep("Save preserves the menu bar's \(enabled ? "enabled" : "disabled") state") {
                editedRow.buttons["virtual_display_edit_button"].click()
                let form = assertExists(app, identifier: "edit_virtual_display_form")
                let hiDPI = assertExists(app, identifier: "virtual_display_edit_mode_hidpi_toggle")
                let originalHiDPI = (hiDPI.value as? NSNumber)?.boolValue
                XCTAssertNotNil(originalHiDPI)
                for _ in 0..<4 where !hiDPI.isHittable {
                    form.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -240)
                }
                XCTAssertTrue(hiDPI.isHittable)
                hiDPI.click()
                let editedHiDPI = (hiDPI.value as? NSNumber)?.boolValue
                XCTAssertEqual(editedHiDPI, originalHiDPI.map { !$0 })

                openQuickActionsPanel(app, excluding: existingMenuBarWindowIDs)
                let menuToggle = rows[1].buttons["menu_bar_virtual_display_toggle_button"]
                XCTAssertTrue(waitForHittable(menuToggle))
                menuToggle.click()
                let expectedLabels = enabled ? ["Disable", "停用"] : ["Enable", "启用"]
                XCTAssertTrue(
                    waitForToggleState(menuToggle, enabled: enabled),
                    "The menu bar toggle did not finish changing the display's enabled state."
                )

                tapIdentifier(app, identifier: "virtual_display_edit_name_field")
                XCTAssertTrue(waitForAbsence(panel, timeout: 2))
                XCTAssertTrue(form.exists, "The original edit form must remain open after the menu bar action.")
                let saveIdentifier = enabled
                    ? "virtual_display_edit_save_only_button"
                    : "virtual_display_edit_save_button"
                tapIdentifier(app, identifier: saveIdentifier)
                XCTAssertTrue(waitForAbsence(form, timeout: 2))
                XCTAssertTrue(
                    expectedLabels.contains(editedRow.buttons["virtual_display_toggle_button"].label),
                    "Saving the edit must preserve the latest enabled intent from the menu bar."
                )
                XCTAssertEqual(editedRow.switches["home_virtual_display_preview_toggle"].isEnabled, enabled)

                editedRow.buttons["virtual_display_edit_button"].click()
                XCTAssertEqual(
                    (assertExists(app, identifier: "virtual_display_edit_mode_hidpi_toggle").value as? NSNumber)?.boolValue,
                    editedHiDPI,
                    "The edited mode must also persist when preserving the menu bar state."
                )
                tapIdentifier(app, identifier: "virtual_display_edit_cancel_button")
                XCTAssertTrue(waitForAbsence(form, timeout: 2))
            }
        }
    }

    @MainActor
    private func waitForToggleState(_ button: XCUIElement, enabled: Bool) -> Bool {
        let expectedLabels = enabled ? ["Disable", "停用"] : ["Enable", "启用"]
        // Runtime queue and catalog updates can outlast UI animations on CI.
        return waitForCondition(timeout: 15, pollInterval: 0.2) {
            button.exists && button.isEnabled && expectedLabels.contains(button.label)
        }
    }

    @MainActor
    private func openQuickActionsPanel(
        _ app: XCUIApplication,
        excluding existingWindowIDs: Set<CGWindowID>
    ) {
        let panel = smokeElement(app, identifier: "menu_bar_quick_actions_panel")
        if panel.exists { return }

        var targetFrame: CGRect?
        XCTAssertTrue(
            waitForCondition(timeout: 6) {
                targetFrame = controlCenterMenuBarWindows()
                    .first(where: { !existingWindowIDs.contains($0.id) })?
                    .frame
                return targetFrame != nil
            },
            "VoidDisplay did not register a new menu bar item window."
        )
        guard let targetFrame else { return }

        let controlCenter = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
        let clock = controlCenter.menuBars.statusItems
            .matching(identifier: "com.apple.menuextra.clock")
            .firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(clock, timeout: 6))

        clock.coordinate(withNormalizedOffset: .zero)
            .withOffset(
                CGVector(
                    dx: targetFrame.midX - clock.frame.minX,
                    dy: targetFrame.midY - clock.frame.minY
                )
            )
            .click()

        XCTAssertTrue(waitForExistenceIfNeeded(panel, timeout: 6))
    }

    private func controlCenterMenuBarWindows() -> [MenuBarWindow] {
        guard let processIdentifier = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter"
        ).first?.processIdentifier else {
            return []
        }
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return windowInfo.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 25,
                  let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else {
                return nil
            }
            return MenuBarWindow(
                id: windowID,
                frame: CGRect(x: x, y: y, width: width, height: height)
            )
        }
    }
}
