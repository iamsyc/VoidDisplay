import XCTest

final class DisplaySceneSmokeTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSaveApplyAndRepairJourney() throws {
        let app = launchAppForSmoke()
        tapIdentifier(app, identifier: "display_scene_save_current_button", timeout: 8)
        let name = assertExists(app, identifier: "display_scene_name_field")
        let sceneName = try XCTUnwrap(name.value as? String)
        XCTAssertFalse(sceneName.isEmpty)
        let second = smokeElement(app, identifier: "display_scene_config_00000000-0000-0000-0000-000000000014")
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        if (second.value as? NSNumber)?.boolValue == true { second.click() }
        tapIdentifier(app, identifier: "display_scene_save_button")
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch.click()
        XCTAssertTrue(waitForAbsence(smokeElement(app, identifier: "display_scene_manager")))
        tapIdentifier(app, identifier: "display_scene_menu")
        app.menuItems[sceneName].click()
        tapIdentifier(app, identifier: "display_scene_confirm_button")
        let completed = app.staticTexts.matching(NSPredicate(format: "value IN %@", ["Display combination applied.", "显示器组合已应用。"])).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 10))
        // Immediately open the edited configuration after the batch; the shared cache must be settled.
        tapIdentifier(app, identifier: "home_virtual_display_more_button")
        tapIdentifier(app, identifier: "virtual_display_edit_button")
        assertExists(app, identifier: "edit_virtual_display_form")
        tapIdentifier(app, identifier: "virtual_display_edit_cancel_button")
        tapIdentifier(app, identifier: "display_scene_save_current_button")
        XCTAssertTrue(app.buttons[sceneName].waitForExistence(timeout: 3))
        app.buttons[sceneName].click()
        XCTAssertEqual((smokeElement(app, identifier: "display_scene_config_00000000-0000-0000-0000-000000000014").value as? NSNumber)?.boolValue, false)
        smokeElement(app, identifier: "display_scene_config_00000000-0000-0000-0000-000000000014").click()
        tapIdentifier(app, identifier: "display_scene_save_button")
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch.click()
        let rows = app.descendants(matching: .any).matching(identifier: "home_virtual_display_list_row")
        let secondMore = rows.matching(NSPredicate(format: "label BEGINSWITH %@", "虚拟显示器 14 寸")).firstMatch
            .descendants(matching: .any).matching(identifier: "home_virtual_display_more_button").firstMatch
        let scroll = app.scrollViews.allElementsBoundByIndex.max { $0.frame.width < $1.frame.width }!
        for _ in 0..<4 where !secondMore.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(secondMore.isHittable)
        secondMore.click()
        app.menuItems["trash"].click()
        app.sheets.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "删除"])).firstMatch.click()
        XCTAssertTrue(waitForCondition(timeout: 8) { rows.count == 1 })
        scroll.scroll(byDeltaX: 0, deltaY: 600)
        tapIdentifier(app, identifier: "display_scene_save_current_button")
        app.buttons[sceneName].click()
        let repair = app.staticTexts.matching(NSPredicate(format: "value IN %@", ["Needs Repair", "需要修复"])).firstMatch
        XCTAssertTrue(repair.exists)
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Remove Missing Display", "移除缺失的显示器"])).firstMatch.click()
        tapIdentifier(app, identifier: "display_scene_save_button")
        XCTAssertTrue(waitForAbsence(repair))
    }
}
