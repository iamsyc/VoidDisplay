import XCTest

enum SmokeScenario: String {
    case baseline
    case permissionDenied = "permission_denied"
}

extension XCTestCase {
    @MainActor
    func launchAppForSmoke(scenario: SmokeScenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FREELYDISPLAY_UI_TEST_MODE"] = "1"
        app.launchEnvironment["FREELYDISPLAY_UI_TEST_SCENARIO"] = scenario.rawValue
        app.launch()
        return app
    }

    @discardableResult
    func assertExists(
        _ app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing identifier: \(identifier)", file: file, line: line)
        return element
    }

    func assertAnyExists(
        _ app: XCUIApplication,
        identifiers: [String],
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in identifiers {
            let exists = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
                .waitForExistence(timeout: timeout)
            if exists {
                return
            }
        }
        XCTFail("None of identifiers exist: \(identifiers.joined(separator: ", "))", file: file, line: line)
    }
}
