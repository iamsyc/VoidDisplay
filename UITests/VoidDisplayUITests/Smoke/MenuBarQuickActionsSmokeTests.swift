import AppKit
import XCTest

final class MenuBarQuickActionsSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPanelActions() throws {
        let app = launchAppForSmoke(
            preferredPort: UITestPortAllocator.randomUnprivilegedPort(),
            scenario: "menu_bar_quick_actions",
            language: "en"
        )
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(mainWindow, timeout: 6))
        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitForAbsence(mainWindow, timeout: 2))
        openQuickActionsPanel(app)

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
        XCTAssertLessThanOrEqual(panel.frame.height, 250)

        let summary = smokeElement(app, identifier: "menu_bar_runtime_summary")
        XCTAssertGreaterThan(panel.frame.height, summary.frame.height)

        let rows = app.descendants(matching: .any)
            .matching(identifier: "menu_bar_virtual_display_row")
            .allElementsBoundByIndex
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(smokeElement(app, identifier: "display_scene_menu").exists)
        XCTAssertTrue(rows.allSatisfy { $0.frame.height <= 80 })
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

        openQuickActionsPanel(app)
        tapIdentifier(app, identifier: "menu_bar_open_main_window_button")
        assertExists(app, identifier: "detail_home", timeout: 4)
        XCTAssertFalse(smokeElement(app, identifier: "capture_preview_waiting_for_identity").exists)

        let homeRows = app.descendants(matching: .any)
            .matching(identifier: "home_virtual_display_list_row")
        XCTAssertEqual(homeRows.count, 2)
        let editedRow = homeRows.matching(NSPredicate(format: "label BEGINSWITH %@", "虚拟显示器 14 寸")).firstMatch
        let editedMore = editedRow.descendants(matching: .any).matching(identifier: "home_virtual_display_more_button").firstMatch
        let homeScroll = app.scrollViews.allElementsBoundByIndex.max { $0.frame.width < $1.frame.width }!
        for _ in 0..<4 where !editedMore.isHittable { homeScroll.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(editedMore.isHittable)

        for enabled in [false, true] {
            performSmokeStep("Save preserves the menu bar's \(enabled ? "enabled" : "disabled") state") {
                editedMore.click()
                app.menuItems["virtual_display_edit_button"].click()
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

                openQuickActionsPanel(app)
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

                editedMore.click()
                app.menuItems["virtual_display_edit_button"].click()
                XCTAssertEqual(
                    (assertExists(app, identifier: "virtual_display_edit_mode_hidpi_toggle").value as? NSNumber)?.boolValue,
                    editedHiDPI,
                    "The edited mode must also persist when preserving the menu bar state."
                )
                tapIdentifier(app, identifier: "virtual_display_edit_cancel_button")
                XCTAssertTrue(waitForAbsence(form, timeout: 2))
            }
        }
        performSmokeStep("Sharing details reuse and stop") {
            openQuickActionsPanel(app)
            rows[0].buttons["menu_bar_web_view_button"].click()
            assertExists(app, identifier: "sharing_session_window", timeout: 10)
            assertExists(app, identifier: "sharing_access_address")
            XCTAssertTrue(smokeElement(app, identifier: "sharing_stop_button").isHittable)
            let sharingScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            sharingScreenshot.name = "Sharing details with isolated test route"
            sharingScreenshot.lifetime = .keepAlways
            add(sharingScreenshot)
            let shareWindow = app.windows.containing(.any, identifier: "sharing_session_window").firstMatch
            shareWindow.buttons[XCUIIdentifierCloseWindow].click()
            openQuickActionsPanel(app)
            rows[0].buttons["menu_bar_sharing_details_button"].click()
            assertExists(app, identifier: "sharing_session_window")
            XCTAssertEqual(app.windows.containing(.any, identifier: "sharing_session_window").count, 1)
            tapIdentifier(app, identifier: "sharing_stop_button")
            XCTAssertTrue(waitForAbsence(smokeElement(app, identifier: "sharing_access_address")))
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
    private func openQuickActionsPanel(_ app: XCUIApplication) {
        let panel = smokeElement(app, identifier: "menu_bar_quick_actions_panel")
        if panel.exists { return }
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(waitForHittable(statusItem, timeout: 6))
        statusItem.click()
        XCTAssertTrue(waitForExistenceIfNeeded(panel, timeout: 6))
    }
}
