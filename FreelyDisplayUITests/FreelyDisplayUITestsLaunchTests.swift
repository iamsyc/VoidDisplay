//
//  FreelyDisplayUITestsLaunchTests.swift
//  FreelyDisplayUITests
//
//  Created by Phineas Guo on 2025/10/4.
//

import XCTest

final class FreelyDisplayUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["FREELYDISPLAY_UI_TEST_MODE"] = "1"
        app.launchEnvironment["FREELYDISPLAY_UI_TEST_SCENARIO"] = "baseline"
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
