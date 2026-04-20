import Foundation
import XCTest

typealias SmokeNamedElement = (identifier: String, element: XCUIElement)

enum SmokeScenario: String {
    case baseline
    case displayCatalogLoading = "display_catalog_loading"
    case permissionDenied = "permission_denied"
    case settingsFeedback = "settings_feedback"
    case virtualDisplayRebuilding = "virtual_display_rebuilding"
    case virtualDisplayRebuildFailed = "virtual_display_rebuild_failed"
}

extension XCTestCase {
    @MainActor
    func configureAppForUITestLaunch(_ app: XCUIApplication) {
        app.launchArguments = [
            "-ApplePersistenceIgnoreState",
            "YES",
            "-NSQuitAlwaysKeepsWindows",
            "NO"
        ]
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
        scenario: SmokeScenario,
        preferredPort: UInt16? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        configureAppForUITestLaunch(app)
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = scenario.rawValue
        if let preferredPort {
            app.launchArguments.append(contentsOf: [
                "-sharing.preferredPort",
                String(preferredPort)
            ])
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
    func assertElementsExist(
        _ elements: [SmokeNamedElement],
        timeout: TimeInterval = 1.2,
        pollInterval: TimeInterval = 0.05,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let missing = elements
                .filter { !$0.element.exists }
                .map(\.identifier)
            if missing.isEmpty {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }

        let missing = elements
            .filter { !$0.element.exists }
            .map(\.identifier)
        XCTAssertTrue(missing.isEmpty, "Missing identifiers: \(missing.joined(separator: ", "))", file: file, line: line)
    }

    @MainActor
    func tapWhenHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 3,
        requireExistenceCheck: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if requireExistenceCheck {
            XCTAssertTrue(
                element.waitForExistence(timeout: timeout),
                "Element does not exist before tap.",
                file: file,
                line: line
            )
        }
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
        tapWhenHittable(
            target,
            in: app,
            timeout: timeout,
            requireExistenceCheck: false,
            file: file,
            line: line
        )
    }

    @MainActor
    func tapByCoordinate(
        _ element: XCUIElement,
        timeout: TimeInterval = 1.5,
        requireExistenceCheck: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if requireExistenceCheck {
            XCTAssertTrue(
                element.waitForExistence(timeout: timeout),
                "Element does not exist before coordinate tap.",
                file: file,
                line: line
            )
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    func waitForIdentifierByPolling(
        _ app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        activateBeforePolling: Bool = false
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if activateBeforePolling {
                app.activate()
            }
            if app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
                .exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
            .exists
    }

    @MainActor
    func waitForCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    @MainActor
    func waitForDisappearance(
        of element: XCUIElement,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> Bool {
        waitForCondition(timeout: timeout, pollInterval: pollInterval) {
            !element.exists
        }
    }

    @MainActor
    func tapFast(
        _ element: XCUIElement,
        in app: XCUIApplication,
        confirmationTimeout: TimeInterval = 0.45,
        fallbackTimeout: TimeInterval = 1.5,
        confirmation: () -> Bool
    ) {
        tapByCoordinate(
            element,
            timeout: 0.4,
            requireExistenceCheck: false
        )
        if waitForCondition(timeout: confirmationTimeout, condition: confirmation) {
            return
        }
        tapWhenHittable(
            element,
            in: app,
            timeout: fallbackTimeout,
            requireExistenceCheck: false
        )
    }
}
