//
//  FreelyDisplayUITests.swift
//  FreelyDisplayUITests
//
//  Created by Phineas Guo on 2025/10/4.
//

import XCTest

final class HomeSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testHomeSmoke() throws {
        let app = XCUIApplication()
        app.launchEnvironment["FREELYDISPLAY_UI_TEST_MODE"] = "1"
        app.launch()

        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "home_sidebar")
            .firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        let sidebarScreen = app.descendants(matching: .any)
            .matching(identifier: "sidebar_screen")
            .firstMatch
        XCTAssertTrue(sidebarScreen.waitForExistence(timeout: 2))

        let defaultDetail = app.descendants(matching: .any)
            .matching(identifier: "detail_screen")
            .firstMatch
        XCTAssertTrue(defaultDetail.waitForExistence(timeout: 2))

        let openSettings = app.descendants(matching: .any)
            .matching(identifier: "displays_open_system_settings")
            .firstMatch
        XCTAssertTrue(openSettings.waitForExistence(timeout: 5))
    }
}
