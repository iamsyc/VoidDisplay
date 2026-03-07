import Foundation
import XCTest

enum SmokeScenario: String {
    case baseline
    case displayCatalogLoading = "display_catalog_loading"
    case permissionDenied = "permission_denied"
    case virtualDisplayRebuilding = "virtual_display_rebuilding"
    case virtualDisplayRebuildFailed = "virtual_display_rebuild_failed"
}

extension XCTestCase {
    @MainActor
    func launchAppForSmoke(
        scenario: SmokeScenario,
        preferredPort: UInt16? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_MODE"] = "1"
        app.launchEnvironment["VOIDDISPLAY_TEST_ISOLATION_ID"] = UUID().uuidString
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = scenario.rawValue
        if let preferredPort {
            app.launchArguments = [
                "-sharing.preferredPort",
                String(preferredPort)
            ]
        }
        app.launch()
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
        let element = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing identifier: \(identifier)", file: file, line: line)
        return element
    }

    @MainActor
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

    @MainActor
    func tapWhenHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Element does not exist before tap.", file: file, line: line)
        let predicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        if XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed {
            element.tap()
            return
        }

        let hierarchySnapshot = app.debugDescription
        XCTContext.runActivity(named: "Accessibility hierarchy snapshot before tap failure") { activity in
            let attachment = XCTAttachment(string: hierarchySnapshot)
            attachment.name = "accessibility-hierarchy.txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        XCTFail("Element exists but is not hittable: \(element)", file: file, line: line)
    }

    @MainActor
    func waitForIdentifierByPolling(
        _ app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> Bool {
        let element = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            app.activate()
            if element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return element.exists
    }
}
