import XCTest

final class PreviewSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPreviewRecoveryRetryRestoresCapture() throws {
        let app = launchAppForSmoke(scenario: "preview_recovery")
        assertAllExist(
            app,
            identifiers: [
                "capture_preview_retry_button",
                "capture_preview_close_button"
            ],
            timeout: 6
        )

        XCTAssertFalse(smokeElement(app, identifier: "capture_preview_cursor_toggle").exists)
        tapIdentifier(app, identifier: "capture_preview_retry_button")

        performSmokeStep("Retry completes through the runtime and restores capture controls") {
            assertExists(app, identifier: "capture_preview_content", timeout: 5)
            assertExists(app, identifier: "capture_preview_cursor_toggle", timeout: 2)
            XCTAssertTrue(waitForAbsence(smokeElement(app, identifier: "capture_preview_retry_button")))
        }
    }

    @MainActor
    func testPreviewRecoveryCloseReleasesWindowState() throws {
        let app = launchAppForSmoke(scenario: "preview_recovery")
        let closeButton = assertExists(app, identifier: "capture_preview_close_button", timeout: 6)
        let previewWindow = app.windows.containing(.button, identifier: "capture_preview_close_button").firstMatch
        XCTAssertTrue(previewWindow.exists)
        closeButton.click()
        XCTAssertTrue(waitForAbsence(previewWindow))
        assertExists(app, identifier: "detail_home", timeout: 3)
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor
    func testPreviewWindowWaitsForIdentityWithoutClosing() throws {
        let app = launchAppForSmoke(scenario: "preview_window_payload")
        let window = app.windows.firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))

        XCTAssertTrue(window.exists)
        let waitingContent = app.descendants(matching: .any)
            .matching(identifier: "capture_preview_waiting_for_identity")
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Preview", "预览"))
            .firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(waitingContent, timeout: 2))
    }

    @MainActor
    func testPreviewActiveWindowUsesDisplayIdentityAndToolbar() throws {
        let app = launchAppForSmoke(scenario: "preview_active")
        let window = app.windows.containing(.any, identifier: "capture_preview_scale_mode_picker").firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(window, timeout: 6))

        let picker = assertExists(app, identifier: "capture_preview_scale_mode_picker", timeout: 3)
        let cursorToggle = assertExists(app, identifier: "capture_preview_cursor_toggle", timeout: 3)
        XCTAssertTrue(picker.isHittable)
        XCTAssertTrue(cursorToggle.isHittable)

        let previewContent = app.descendants(matching: .any)
            .matching(identifier: "capture_preview_content")
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    "1920",
                    "1080"
                )
            )
            .firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(previewContent, timeout: 3))
        XCTAssertTrue(previewContent.label.contains("1920 × 1080"))
        XCTAssertTrue(["Preview", "预览"].contains { previewContent.label.contains($0) })

        let nativeScale = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "1:1"))
            .firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(nativeScale, timeout: 2))
        nativeScale.click()
        XCTAssertEqual(picker.value as? String, "1:1")

        cursorToggle.click()
        XCTAssertEqual((cursorToggle.value as? NSNumber)?.boolValue, true)

        let closeButton = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(waitForExistenceIfNeeded(closeButton, timeout: 2))
        app.activate()
        let closeWindowItem = app.menuItems.matching(
            NSPredicate(format: "title IN %@", ["Close Window", "Close", "关闭窗口", "关闭"])
        ).firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(closeWindowItem, timeout: 2))
        closeWindowItem.click()
        XCTAssertTrue(waitForAbsence(window, timeout: 3))

        app.activate()
        let openMainWindowItem = app.menuItems.matching(
            NSPredicate(format: "title IN %@", ["Open VoidDisplay", "打开 VoidDisplay"])
        ).firstMatch
        XCTAssertTrue(waitForExistenceIfNeeded(openMainWindowItem, timeout: 2))
        XCTAssertFalse(app.menuItems["New Window"].exists)
        XCTAssertFalse(app.menuItems["新建窗口"].exists)
        openMainWindowItem.click()
        assertAllExist(
            app,
            identifiers: ["detail_home", "home_virtual_display_preview_toggle"],
            timeout: 4
        )
        let previewToggle = app.switches
            .matching(identifier: "home_virtual_display_preview_toggle")
            .firstMatch
        XCTAssertEqual((previewToggle.value as? NSNumber)?.boolValue, false)
        XCTAssertFalse(smokeElement(app, identifier: "capture_preview_waiting_for_identity").exists)
        XCTAssertEqual(app.windows.count, 1)
    }
}
