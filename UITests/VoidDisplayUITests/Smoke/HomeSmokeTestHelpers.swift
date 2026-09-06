import XCTest

extension XCTestCase {
    @MainActor
    func assertHomePageActionsAreInToolbar(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toolbar = app.toolbars.firstMatch
        XCTAssertTrue(
            waitForExistenceIfNeeded(toolbar, timeout: 2),
            "Missing window toolbar",
            file: file,
            line: line
        )

        XCTAssertTrue(
            waitForCondition(timeout: 6) {
                homePageActionIdentifiers.allSatisfy { identifier in
                    toolbar.descendants(matching: .any)
                        .matching(identifier: identifier)
                        .firstMatch
                        .exists
                }
            },
            "Home page actions did not finish entering the toolbar.",
            file: file,
            line: line
        )

        for identifier in homePageActionIdentifiers {
            let element = toolbar.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            XCTAssertTrue(
                element.exists,
                "Page action is outside the toolbar: \(identifier)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    func assertHomePageActionsAreAbsent(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in homePageActionIdentifiers {
            let element = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            XCTAssertTrue(
                waitForAbsence(element, timeout: 0.5),
                "Home page action remained visible outside Home: \(identifier)",
                file: file,
                line: line
            )
        }
    }

    var homePageActionIdentifiers: [String] {
        [
            "home_rescan_displays_button",
            "home_sharing_settings_popover_button",
            "home_add_virtual_display_button"
        ]
    }

    @MainActor
    func assertSelectedSidebarHasKeyboardFocus(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertExists(
            app,
            identifier: "sidebar_home",
            timeout: 2,
            file: file,
            line: line
        )
        assertExists(
            app,
            identifier: "detail_home",
            timeout: 2,
            file: file,
            line: line
        )

        let focusedSidebar = app.outlines
            .matching(identifier: "home_sidebar")
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        XCTAssertTrue(
            waitForExistenceIfNeeded(focusedSidebar, timeout: 2),
            "Selected sidebar did not receive keyboard focus.",
            file: file,
            line: line
        )
    }

    @MainActor
    func assertSingleFormLabel(
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
