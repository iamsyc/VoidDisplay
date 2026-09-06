import XCTest

final class VirtualDisplaySmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateEditAndRebuildJourney() throws {
        let app = launchAppForSmoke()

        performSmokeStep("Create form and cancel") {
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
            XCTAssertTrue(waitForAbsence(smokeElement(app, identifier: "virtual_display_create_form"), timeout: 1))
        }

        performSmokeStep("Edit form and cancel") {
            tapIdentifier(app, identifier: "virtual_display_edit_button", timeout: 3)
            assertAllExist(
                app,
                identifiers: ["edit_virtual_display_form", "virtual_display_edit_cancel_button"],
                timeout: 3
            )
            assertSingleFormLabel(app, english: "Screen Size", chinese: "屏幕尺寸")
            assertSingleFormLabel(app, english: "Serial Number", chinese: "序列号")
            tapIdentifier(app, identifier: "virtual_display_edit_cancel_button")
            XCTAssertTrue(waitForAbsence(smokeElement(app, identifier: "edit_virtual_display_form"), timeout: 1))
        }

        performSmokeStep("Save the edited mode, reopen it and rebuild") {
            tapIdentifier(app, identifier: "virtual_display_edit_button")
            let hiDPI = assertExists(app, identifier: "virtual_display_edit_mode_hidpi_toggle")
            let form = smokeElement(app, identifier: "edit_virtual_display_form")
            for _ in 0..<4 where !hiDPI.isHittable {
                form.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -240)
            }
            XCTAssertTrue(hiDPI.isHittable)
            hiDPI.click()
            XCTAssertEqual((hiDPI.value as? NSNumber)?.boolValue, true)
            tapIdentifier(app, identifier: "virtual_display_edit_save_only_button")
            XCTAssertTrue(waitForAbsence(form, timeout: 1))

            let appliedBadge = app.staticTexts.matching(
                NSPredicate(format: "value IN %@", ["Applied", "已应用"])
            ).firstMatch
            XCTAssertFalse(appliedBadge.exists)
            tapIdentifier(app, identifier: "virtual_display_edit_button")
            XCTAssertEqual(
                (assertExists(app, identifier: "virtual_display_edit_mode_hidpi_toggle").value as? NSNumber)?.boolValue,
                true,
                "Save Only must persist the edited mode before reopening the form."
            )
            tapIdentifier(app, identifier: "virtual_display_edit_save_and_rebuild_button")
            // Rebuild saves through the runtime queue before dismissing the form.
            XCTAssertTrue(waitForAbsence(form))
            XCTAssertTrue(
                appliedBadge.waitForExistence(timeout: 8),
                "Reopening an unchanged saved configuration must still execute the requested rebuild."
            )
        }

    }
}
