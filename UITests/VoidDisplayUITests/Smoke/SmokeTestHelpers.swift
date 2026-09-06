import Foundation
import XCTest

extension XCTestCase {
    @MainActor
    func performSmokeStep<Result>(_ title: String, _ body: () throws -> Result) rethrows -> Result {
        print("[UI_STEP] \(title)")
        defer { print("[UI_STEP_END] \(title)") }
        return try XCTContext.runActivity(named: title) { _ in try body() }
    }

    @MainActor
    func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        waitForCondition(timeout: timeout) { !element.exists }
    }

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
        if let windowSize {
            app.launchEnvironment["VOIDDISPLAY_UI_TEST_WINDOW_WIDTH"] = String(windowSize.width)
            app.launchEnvironment["VOIDDISPLAY_UI_TEST_WINDOW_HEIGHT"] = String(windowSize.height)
        }
        if advanceFocus {
            app.launchEnvironment["VOIDDISPLAY_UI_TEST_ADVANCE_FOCUS"] = "1"
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
        let element = smokeElement(app, identifier: identifier)
        XCTAssertTrue(
            waitForExistenceIfNeeded(element, timeout: timeout),
            "Missing identifier: \(identifier)",
            file: file,
            line: line
        )
        return element
    }

    @MainActor
    func waitForExistenceIfNeeded(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        element.exists || element.waitForExistence(timeout: timeout)
    }

    @MainActor
    func waitForCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        _ condition: () -> Bool
    ) -> Bool {
        if condition() {
            return true
        }

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(pollInterval))
            if condition() {
                return true
            }
        }
        return condition()
    }

    @MainActor
    func resizeWindow(
        _ window: XCUIElement,
        to targetSize: CGSize,
        timeout: TimeInterval = 3,
        accuracy: CGFloat = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitForExistenceIfNeeded(window, timeout: timeout),
            "Window must exist before resizing.",
            file: file,
            line: line
        )

        let initialFrame = window.frame
        let topLeft = window.coordinate(withNormalizedOffset: .zero)
        let resizeHandle = topLeft.withOffset(
            CGVector(dx: initialFrame.width - 2, dy: initialFrame.height - 2)
        )
        let target = topLeft.withOffset(
            CGVector(dx: targetSize.width - 2, dy: targetSize.height - 2)
        )
        resizeHandle.click(forDuration: 0.1, thenDragTo: target)

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            let frame = window.frame
            if abs(frame.width - targetSize.width) <= accuracy,
               abs(frame.height - targetSize.height) <= accuracy
            {
                return
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }

        XCTAssertEqual(window.frame.width, targetSize.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(window.frame.height, targetSize.height, accuracy: accuracy, file: file, line: line)
    }

    @MainActor
    func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.05
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return element.isHittable
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
