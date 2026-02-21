//
//  VoidDisplayUITestsLaunchTests.swift
//  VoidDisplayUITests
//
//

import XCTest

final class VoidDisplayUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchHealthCheck_baselineShellIsVisible() throws {
        let app = launchAppForSmoke(scenario: .baseline)

        assertExists(app, identifier: "home_sidebar")
        assertExists(app, identifier: "sidebar_screen")
        assertExists(app, identifier: "detail_screen")
        assertExists(app, identifier: "displays_open_system_settings")
    }
}
