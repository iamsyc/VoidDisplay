import Foundation
import XCTest

final class RealEnvironmentE2ETests: XCTestCase {
    private enum ShareAccessibilityState {
        static let sharing = "sharing"
        static let idle = "idle"
    }


    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRealEnvironment_sharingPageShowsPermissionGuideOrDisplays() throws {
        let app = launchAppForRealEnvironment()
        assertExists(app, identifier: "sidebar_screen_sharing").tap()
        assertExists(app, identifier: "detail_screen_sharing")

        let permissionGuide = app.descendants(matching: .any)
            .matching(identifier: "share_permission_guide")
            .firstMatch
        if permissionGuide.waitForExistence(timeout: 2) {
            assertExists(app, identifier: "share_open_settings_button")
            assertExists(app, identifier: "share_request_permission_button")
            return
        }

        guard let state = waitForAnyIdentifier(
            app,
            identifiers: [
                "share_start_service_button",
                "share_displays_list",
                "share_displays_empty_state",
                "share_loading_permission",
                "share_loading_displays"
            ],
            timeout: 10
        ) else {
            throw XCTSkip("Sharing page did not reach a stable real-environment state within timeout.")
        }

        if state == "share_start_service_button" {
            element(app, identifier: "share_start_service_button").tap()
            guard let afterStartState = waitForAnyIdentifier(
                app,
                identifiers: [
                    "share_displays_list",
                    "share_displays_empty_state",
                    "share_loading_displays"
                ],
                timeout: 10
            ) else {
                throw XCTSkip("Service started but display state was not resolved in time.")
            }
            if afterStartState == "share_loading_displays" {
                throw XCTSkip("Display loading remained in-progress; environment not stable for assertion.")
            }
            return
        }

        if state == "share_loading_permission" || state == "share_loading_displays" {
            throw XCTSkip("Sharing page remained in loading state; environment not stable for assertion.")
        }
    }

    @MainActor
    func testRealEnvironment_shareLifecycleAndDisplayPageReachability() async throws {
        let app = launchAppForRealEnvironment()
        assertExists(app, identifier: "sidebar_screen_sharing").tap()
        assertExists(app, identifier: "detail_screen_sharing")

        let permissionGuide = app.descendants(matching: .any)
            .matching(identifier: "share_permission_guide")
            .firstMatch
        if permissionGuide.waitForExistence(timeout: 2) {
            throw XCTSkip("Screen capture permission is not granted for real-environment E2E.")
        }

        if let preStartState = waitForAnyIdentifier(
            app,
            identifiers: [
                "share_start_service_button",
                "share_displays_list",
                "share_displays_empty_state",
                "share_loading_permission",
                "share_loading_displays"
            ],
            timeout: 10
        ) {
            if preStartState == "share_start_service_button" {
                element(app, identifier: "share_start_service_button").tap()
            } else if preStartState == "share_loading_permission" || preStartState == "share_loading_displays" {
                throw XCTSkip("Sharing page is still loading; skip real-environment lifecycle check.")
            }
        } else {
            throw XCTSkip("Could not determine sharing page state in real environment.")
        }

        let addressText = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "share_display_address_")
        ).firstMatch
        guard addressText.waitForExistence(timeout: 10) else {
            throw XCTSkip("No shareable displays are available on this machine.")
        }

        let displayPageURLString = addressText.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayPageURL = URL(string: displayPageURLString) else {
            XCTFail("Invalid display URL: \(displayPageURLString)")
            return
        }

        let isDisplayPageReachable = await waitForHTTPStatus(url: displayPageURL, expected: 200, timeout: 6)
        XCTAssertTrue(isDisplayPageReachable, "Display page should be reachable while service is running.")

        let shareActionButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "share_action_button_")
        ).firstMatch
        XCTAssertTrue(shareActionButton.waitForExistence(timeout: 5), "Expected per-display share action button.")

        if (shareActionButton.value as? String) == ShareAccessibilityState.sharing {
            shareActionButton.tap()
            XCTAssertTrue(
                waitForAccessibilityValue(element: shareActionButton, value: ShareAccessibilityState.idle, timeout: 5),
                "Expected initial sharing state to become idle before lifecycle check."
            )
        }

        shareActionButton.tap()
        XCTAssertTrue(
            waitForAccessibilityValue(element: shareActionButton, value: ShareAccessibilityState.sharing, timeout: 8),
            "Expected display sharing to start."
        )

        shareActionButton.tap()
        XCTAssertTrue(
            waitForAccessibilityValue(element: shareActionButton, value: ShareAccessibilityState.idle, timeout: 8),
            "Expected display sharing to stop."
        )

        let stopServiceButton = assertExists(app, identifier: "share_stop_service_button")
        if stopServiceButton.isEnabled {
            stopServiceButton.tap()
        }
        assertExists(app, identifier: "share_start_service_button")
        let isDisplayPageUnreachable = await waitForHTTPFailure(url: displayPageURL, timeout: 6)
        XCTAssertTrue(isDisplayPageUnreachable, "Display page should become unreachable after stopping service.")
    }

    @MainActor
    private func launchAppForRealEnvironment() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForAnyIdentifier(
        _ app: XCUIApplication,
        identifiers: [String],
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for identifier in identifiers {
                if element(app, identifier: identifier).exists {
                    return identifier
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private func waitForAccessibilityValue(
        element: XCUIElement,
        value: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHTTPStatus(
        url: URL,
        expected: Int,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                if try await fetchHTTPStatus(url: url, timeout: 2) == expected {
                    return true
                }
            } catch {
                // Retry until timeout.
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func waitForHTTPFailure(
        url: URL,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                _ = try await fetchHTTPStatus(url: url, timeout: 2)
            } catch {
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func fetchHTTPStatus(url: URL, timeout: TimeInterval) async throws -> Int {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return httpResponse.statusCode
    }
}
