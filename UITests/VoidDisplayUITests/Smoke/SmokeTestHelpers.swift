import Foundation
import XCTest

extension XCTestCase {
    @MainActor
    func configureAppForWindowRestorationIsolatedLaunch(_ app: XCUIApplication) {
        app.launchArguments = [
            "-ApplePersistenceIgnoreState",
            "YES",
            "-NSQuitAlwaysKeepsWindows",
            "NO"
        ]
    }

    @MainActor
    func configureAppForUITestLaunch(_ app: XCUIApplication) {
        configureAppForWindowRestorationIsolatedLaunch(app)
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_MODE"] = "1"
        app.launchEnvironment["VOIDDISPLAY_TEST_ISOLATION_ID"] = UUID().uuidString
    }

    @MainActor
    func smokeElement(
        _ app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    @MainActor
    func launchAppForSmoke(
        preferredPort: UInt16? = nil,
        homeLayoutID: String? = nil,
        windowSize: (width: Int, height: Int)? = nil,
        advanceFocus: Bool = false,
        scenario: String = "baseline"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        configureAppForUITestLaunch(app)
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = scenario
        if let preferredPort {
            app.launchArguments.append(contentsOf: [
                "-sharing.preferredPort",
                String(preferredPort)
            ])
        }
        if let homeLayoutID {
            app.launchArguments.append(contentsOf: [
                "-appearance.homeLayoutID",
                homeLayoutID
            ])
        }
        if let windowSize {
            app.launchEnvironment["VOIDDISPLAY_UI_TEST_WINDOW_WIDTH"] = String(windowSize.width)
            app.launchEnvironment["VOIDDISPLAY_UI_TEST_WINDOW_HEIGHT"] = String(windowSize.height)
        }
        if advanceFocus {
            app.launchEnvironment["VOIDDISPLAY_UI_TEST_ADVANCE_FOCUS"] = "1"
        }
        app.launch()
        app.activate()
        return app
    }

    @discardableResult
    @MainActor
    func assertExists(
        _ app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = smokeElement(app, identifier: identifier)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing identifier: \(identifier)", file: file, line: line)
        return element
    }

    @MainActor
    func assertAllExist(
        _ app: XCUIApplication,
        identifiers: [String],
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.05,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let missing = identifiers.filter { identifier in
                !app.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .firstMatch
                    .exists
            }
            if missing.isEmpty {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }

        let missing = identifiers.filter { identifier in
            !app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
                .exists
        }
        XCTAssertTrue(missing.isEmpty, "Missing identifiers: \(missing.joined(separator: ", "))", file: file, line: line)
    }

    @MainActor
    func tapIdentifier(
        _ app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval = 1.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = assertExists(
            app,
            identifier: identifier,
            timeout: timeout,
            file: file,
            line: line
        )
        target.tap()
    }

}
