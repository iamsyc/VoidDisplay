import Foundation
import CoreGraphics
import XCTest

/// 手工环境验证套件。
/// 这组测试依赖真实权限、真实网络和真实桌面环境，不属于默认回归入口。
/// 仅在显式设置 `VOIDDISPLAY_RUN_REAL_ENV_E2E=1` 时执行。
final class RealEnvironmentE2ETests: XCTestCase {
    /// Must stay in sync with `SharingPortPreferenceKeys.preferredPort` in app target.
    private static let preferredPortLaunchArgumentKey = "sharing.preferredPort"
    private static let runEnvironmentKey = "VOIDDISPLAY_RUN_REAL_ENV_E2E"
    private static let persistenceModeEnvironmentKey = "VOIDDISPLAY_PERSISTENCE_MODE"
    private static let testIsolationIDEnvironmentKey = "VOIDDISPLAY_TEST_ISOLATION_ID"
    private static let testIsolatedPersistenceMode = "test_isolated"

    private enum ShareAccessibilityState {
        static let sharing = "sharing"
        static let idle = "idle"
    }

    private enum SharePageState: String, CaseIterable {
        case permissionGuide = "share_permission_guide"
        case loadingPermission = "share_loading_permission"
        case startServiceButton = "share_start_service_button"
        case displaysList = "share_displays_list"
        case displaysEmptyState = "share_displays_empty_state"
        case loadingDisplays = "share_loading_displays"
    }

    private struct RealEnvironmentFailure: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private let maxStartPortAttempts = 8
    private var realEnvironmentIsolationID = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.runEnvironmentKey] == "1",
            "Set \(Self.runEnvironmentKey)=1 to run real-environment UI tests."
        )
    }

    @MainActor
    func testRealEnvironment_sharingPageShowsPermissionGuideOrDisplays() throws {
        let app = launchAppForRealEnvironment()
        try openSharingPage(app)

        let permissionGuide = element(app, identifier: SharePageState.permissionGuide.rawValue)
        if permissionGuide.waitForExistence(timeout: 2) {
            assertExists(app, identifier: "share_open_settings_button")
            assertExists(app, identifier: "share_request_permission_button")
            return
        }

        guard let state = waitForSharePageState(
            app,
            states: [
                .permissionGuide,
                .loadingPermission,
                .startServiceButton,
                .displaysList,
                .displaysEmptyState,
                .loadingDisplays
            ],
            timeout: 10
        ) else {
            throw failure(
                "Sharing page did not reach a stable real-environment state within timeout. " +
                shareStartDiagnostics(app)
            )
        }

        switch state {
        case .permissionGuide:
            assertExists(app, identifier: "share_open_settings_button")
            assertExists(app, identifier: "share_request_permission_button")
        case .startServiceButton:
            _ = try startServiceWithDynamicPortIfNeeded(app, initialState: state)
        case .displaysList, .displaysEmptyState:
            return
        case .loadingPermission, .loadingDisplays:
            throw failure("Sharing page remained in loading state (\(state.rawValue)). \(shareStartDiagnostics(app))")
        }
    }

    @MainActor
    func testRealEnvironment_shareLifecycleAndDisplayPageReachability() async throws {
        let app = launchAppForRealEnvironment()
        try openSharingPage(app)

        let permissionGuide = element(app, identifier: SharePageState.permissionGuide.rawValue)
        if permissionGuide.waitForExistence(timeout: 2) {
            throw failure(
                "Real-environment E2E requires screen capture permission, but permission guide is visible."
            )
        }

        var dynamicStartSummary = "attemptedPorts=[], lastPortError=none"

        guard let preStartState = waitForSharePageState(
            app,
            states: [
                .permissionGuide,
                .loadingPermission,
                .startServiceButton,
                .displaysList,
                .displaysEmptyState,
                .loadingDisplays
            ],
            timeout: 10
        ) else {
            throw failure("Could not determine sharing page state in real environment. \(shareStartDiagnostics(app))")
        }

        switch preStartState {
        case .permissionGuide:
            throw failure("Permission guide became visible before lifecycle check. \(shareStartDiagnostics(app))")
        case .startServiceButton:
            let startOutcome = try startServiceWithDynamicPortIfNeeded(app, initialState: preStartState)
            dynamicStartSummary = startOutcome.diagnosticsSummary
        case .displaysList, .displaysEmptyState:
            break
        case .loadingPermission, .loadingDisplays:
            throw failure("Sharing page is still loading (\(preStartState.rawValue)); cannot run lifecycle check.")
        }

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

        guard let displayPageURL = waitForDisplayPageURL(app, timeout: 10) else {
            throw failure(
                "No valid share display URL was produced after sharing started. " +
                "\(dynamicStartSummary) \(shareStartDiagnostics(app))"
            )
        }

        let isDisplayPageReachable = await waitForHTTPStatus(url: displayPageURL, expected: 200, timeout: 6)
        XCTAssertTrue(isDisplayPageReachable, "Display page should be reachable while service is running.")

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
        realEnvironmentIsolationID = UUID().uuidString
        launchApp(app, isolationID: realEnvironmentIsolationID, preferredPort: nil)
        return app
    }

    @MainActor
    private func openSharingPage(_ app: XCUIApplication) throws {
        app.activate()
        try skipIfBlockingSystemDialogIsPresent(operation: "open sharing page")
        assertExists(app, identifier: "sidebar_screen").tap()
        assertExists(app, identifier: "displays_action_open_lan_web_view").tap()
        try skipIfBlockingSystemDialogIsPresent(operation: "open sharing page")
        assertExists(app, identifier: "detail_screen_sharing")
    }

    @MainActor
    private func element(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func waitForSharePageState(
        _ app: XCUIApplication,
        states: [SharePageState] = SharePageState.allCases,
        timeout: TimeInterval
    ) -> SharePageState? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            app.activate()
            if hasShareActionButton(app) {
                return .displaysList
            }
            for state in states {
                if element(app, identifier: state.rawValue).exists {
                    return state
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    @MainActor
    private func hasShareActionButton(_ app: XCUIApplication) -> Bool {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "share_action_button_")
        ).firstMatch.exists
    }

    @MainActor
    private func waitForDisplayPageURL(
        _ app: XCUIApplication,
        timeout: TimeInterval
    ) -> URL? {
        let query = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "share_display_address_")
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = query.count
            for index in 0..<count {
                let candidate = query.element(boundBy: index)
                guard candidate.exists else { continue }

                let labelValue = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let valueValue = (candidate.value as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rawValue = labelValue.isEmpty ? valueValue : labelValue

                guard !rawValue.isEmpty, let url = URL(string: rawValue) else { continue }
                guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    continue
                }
                guard url.host != nil else { continue }
                return url
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    @MainActor
    private func waitForAccessibilityValue(
        element: XCUIElement,
        value: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func shareStartDiagnostics(_ app: XCUIApplication) -> String {
        let startVisible = element(app, identifier: SharePageState.startServiceButton.rawValue).exists
        let listVisible = element(app, identifier: SharePageState.displaysList.rawValue).exists
        let emptyVisible = element(app, identifier: SharePageState.displaysEmptyState.rawValue).exists
        let loadingVisible = element(app, identifier: SharePageState.loadingDisplays.rawValue).exists
        let loadingPermissionVisible = element(app, identifier: SharePageState.loadingPermission.rawValue).exists
        let permissionGuideVisible = element(app, identifier: SharePageState.permissionGuide.rawValue).exists
        let portError = inlinePortErrorText(app) ?? "none"
        let uiPort = currentPortInputText(app) ?? "n/a"
        let urlPort = currentDisplayAddressPort(app).map(String.init) ?? "n/a"
        return "diag[start=\(startVisible), list=\(listVisible), empty=\(emptyVisible), loading=\(loadingVisible), loadingPermission=\(loadingPermissionVisible), permissionGuide=\(permissionGuideVisible), portError=\(portError), uiPort=\(uiPort), urlPort=\(urlPort)]"
    }

    @MainActor
    private func startServiceWithDynamicPortIfNeeded(
        _ app: XCUIApplication,
        initialState: SharePageState
    ) throws -> DynamicStartOutcome {
        guard initialState == .startServiceButton else {
            return DynamicStartOutcome(state: initialState, attemptedPorts: [], lastPortError: nil)
        }

        let candidatePorts = UITestPortAllocator.randomPortCandidates(count: maxStartPortAttempts)
        var attemptedPorts: [UInt16] = []
        var lastPortError: String?
        let isolationID = realEnvironmentIsolationID

        for candidate in candidatePorts {
            attemptedPorts.append(candidate)
            try relaunchAppToSharingPage(app, isolationID: isolationID, preferredPort: candidate)

            guard let currentState = waitForSharePageState(
                app,
                states: [
                    .permissionGuide,
                    .loadingPermission,
                    .startServiceButton,
                    .displaysList,
                    .displaysEmptyState,
                    .loadingDisplays
                ],
                timeout: 10
            ) else {
                throw failure(
                    "Failed to resolve current sharing state before start attempt. attemptedPorts=\(attemptedPorts), " +
                    "lastPortError=\(lastPortError ?? "none"), \(shareStartDiagnostics(app))"
                )
            }

            switch currentState {
            case .displaysList, .displaysEmptyState:
                return DynamicStartOutcome(
                    state: currentState,
                    attemptedPorts: attemptedPorts,
                    lastPortError: lastPortError
                )
            case .permissionGuide:
                throw failure("Permission guide appeared during start attempts. \(shareStartDiagnostics(app))")
            case .loadingPermission, .loadingDisplays:
                throw failure("Unexpected loading state before start attempt (\(currentState.rawValue)). \(shareStartDiagnostics(app))")
            case .startServiceButton:
                let uiPort = currentPortInputText(app) ?? "n/a"
                print(
                    "[RealEnvironmentE2ETests] dynamic start attempt requestedPort=\(candidate) uiPort=\(uiPort) state=\(currentState.rawValue) attemptedPorts=\(attemptedPorts)"
                )
                break
            }

            let startButton = element(app, identifier: SharePageState.startServiceButton.rawValue)
            guard startButton.waitForExistence(timeout: 2) else {
                throw failure("Start Service button disappeared before attempt. attemptedPorts=\(attemptedPorts)")
            }
            try tapOrFailIfBlocked(
                startButton,
                app: app,
                operation: "tap start service button"
            )

            let states: [SharePageState] = [
                .permissionGuide,
                .loadingPermission,
                .startServiceButton,
                .displaysList,
                .displaysEmptyState,
                .loadingDisplays
            ]

            let nextState: SharePageState
            if let resolved = waitForSharePageState(
                app,
                states: states,
                timeout: 8
            ) {
                nextState = resolved
            } else {
                try openSharingPage(app)
                guard let recovered = waitForSharePageState(
                    app,
                    states: states,
                    timeout: 6
                ) else {
                    if waitForDisplayPageURL(app, timeout: 5) != nil {
                        return DynamicStartOutcome(
                            state: .displaysList,
                            attemptedPorts: attemptedPorts,
                            lastPortError: lastPortError
                        )
                    }
                    lastPortError = inlinePortErrorText(app) ?? lastPortError
                    throw failure(
                        "Share page did not reach a stable state after start attempt. attemptedPorts=\(attemptedPorts), " +
                        "lastPortError=\(lastPortError ?? "none"), \(shareStartDiagnostics(app))"
                    )
                }
                nextState = recovered
            }

            switch nextState {
            case .displaysList, .displaysEmptyState:
                let uiPort = currentPortInputText(app) ?? "n/a"
                let urlPort = currentDisplayAddressPort(app).map(String.init) ?? "n/a"
                print(
                    "[RealEnvironmentE2ETests] dynamic start success requestedPort=\(candidate) uiPort=\(uiPort) urlPort=\(urlPort) state=\(nextState.rawValue) attemptedPorts=\(attemptedPorts)"
                )
                return DynamicStartOutcome(
                    state: nextState,
                    attemptedPorts: attemptedPorts,
                    lastPortError: lastPortError
                )
            case .permissionGuide:
                throw failure("Permission guide appeared after start attempt. attemptedPorts=\(attemptedPorts)")
            case .loadingPermission, .loadingDisplays:
                throw failure("Sharing page remained in loading state (\(nextState.rawValue)) after start attempt. attemptedPorts=\(attemptedPorts)")
            case .startServiceButton:
                lastPortError = inlinePortErrorText(app) ?? lastPortError
                if waitForDisplayPageURL(app, timeout: 3) != nil {
                    return DynamicStartOutcome(
                        state: .displaysList,
                        attemptedPorts: attemptedPorts,
                        lastPortError: lastPortError
                    )
                }
                guard isRetryableStartError(lastPortError) else {
                    throw failure(
                        "Service returned to start state with non-retryable error. attemptedPorts=\(attemptedPorts), " +
                        "lastPortError=\(lastPortError ?? "none"), \(shareStartDiagnostics(app))"
                    )
                }
                let uiPort = currentPortInputText(app) ?? "n/a"
                let urlPort = currentDisplayAddressPort(app).map(String.init) ?? "n/a"
                print(
                    "[RealEnvironmentE2ETests] dynamic start retry requestedPort=\(candidate) uiPort=\(uiPort) urlPort=\(urlPort) lastPortError=\(lastPortError ?? "none") attemptedPorts=\(attemptedPorts)"
                )
            }
        }

        throw failure(
            "Failed to start service after dynamic port retries. attemptedPorts=\(attemptedPorts), " +
            "lastPortError=\(lastPortError ?? "none"), \(shareStartDiagnostics(app))"
        )
    }

    @MainActor
    private func launchApp(
        _ app: XCUIApplication,
        isolationID: String,
        preferredPort: UInt16?
    ) {
        configureAppForWindowRestorationIsolatedLaunch(app)
        app.launchEnvironment[Self.persistenceModeEnvironmentKey] = Self.testIsolatedPersistenceMode
        app.launchEnvironment[Self.testIsolationIDEnvironmentKey] = isolationID
        if let preferredPort {
            app.launchArguments.append(contentsOf: [
                "-\(Self.preferredPortLaunchArgumentKey)",
                String(preferredPort)
            ])
        }
        app.launch()
    }

    @MainActor
    private func relaunchAppToSharingPage(
        _ app: XCUIApplication,
        isolationID: String,
        preferredPort: UInt16?
    ) throws {
        app.terminate()
        launchApp(app, isolationID: isolationID, preferredPort: preferredPort)
        try openSharingPage(app)
    }

    @MainActor
    private func skipIfBlockingSystemDialogIsPresent(operation: String) throws {
        let userNotificationCenter = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        let systemDialog = userNotificationCenter.dialogs.firstMatch
        if systemDialog.exists {
            throw XCTSkip(
                "System dialog blocked '\(operation)' in RealEnvironmentE2E. dialog=\(systemDialog.label)"
            )
        }
    }

    @MainActor
    private func failIfSystemInterruptionIsPresent(
        _ app: XCUIApplication,
        operation: String
    ) throws {
        let interruption = app.dialogs.firstMatch
        if interruption.exists {
            _ = dismissInterruptionIfPossible(interruption)
        }
        guard interruption.exists else { return }
        throw failure(
            "System interruption blocked '\(operation)' in RealEnvironmentE2E. dialog=\(interruption.label)"
        )
    }

    @MainActor
    private func dismissInterruptionIfPossible(_ interruption: XCUIElement) -> Bool {
        let preferredButtons = [
            "Allow", "OK", "Continue", "Open System Settings",
            "允许", "好", "确定", "继续", "打开“系统设置”"
        ]
        for title in preferredButtons {
            let button = interruption.buttons[title]
            if button.exists {
                button.tap()
                return true
            }
        }
        let firstButton = interruption.buttons.firstMatch
        if firstButton.exists {
            firstButton.tap()
            return true
        }
        return false
    }

    @MainActor
    private func inlinePortErrorText(_ app: XCUIApplication) -> String? {
        let errorText = element(app, identifier: "share_port_error_text")
        guard errorText.exists else { return nil }

        let labelText = errorText.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !labelText.isEmpty { return labelText }

        if let valueText = (errorText.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !valueText.isEmpty {
            return valueText
        }
        return nil
    }

    @MainActor
    private func currentPortInputText(_ app: XCUIApplication) -> String? {
        let field = element(app, identifier: "share_port_input")
        guard field.exists else { return nil }

        if let value = (field.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           value.lowercased() != "text field" {
            return value
        }

        let label = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return label
    }

    @MainActor
    private func currentDisplayAddressPort(_ app: XCUIApplication) -> Int? {
        let query = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "share_display_address_")
        )
        let count = query.count
        for index in 0..<count {
            let candidate = query.element(boundBy: index)
            guard candidate.exists else { continue }

            let labelValue = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let valueValue = (candidate.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawValue = labelValue.isEmpty ? valueValue : labelValue
            guard !rawValue.isEmpty, let url = URL(string: rawValue) else { continue }
            if let port = url.port {
                return port
            }
        }
        return nil
    }

    @MainActor
    private func tapOrFailIfBlocked(
        _ element: XCUIElement,
        app: XCUIApplication,
        operation: String
    ) throws {
        guard element.waitForExistence(timeout: 2) else {
            throw failure("Required element disappeared before interaction.")
        }

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            try failIfSystemInterruptionIsPresent(app, operation: operation)
            if element.isHittable {
                element.tap()
                return
            }
            app.activate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        // Fallback to coordinate tap to reduce false negatives when accessibility
        // reports a visible button as temporarily non-hittable.
        let center = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
    }

    private func isRetryableStartError(_ message: String?) -> Bool {
        guard let normalizedMessage = message?.lowercased(), !normalizedMessage.isEmpty else {
            return false
        }

        let markers = [
            "port in use",
            "address already in use",
            "eaddrinuse",
            "已被占用",
            "被占用",
            "端口",
            "occupied",
            "superseded",
            "新的请求替代",
            "请求已被新的请求替代"
        ]

        return markers.contains { normalizedMessage.contains($0) }
    }

    private func failure(_ message: String) -> RealEnvironmentFailure {
        RealEnvironmentFailure(message: message)
    }

    private struct DynamicStartOutcome {
        let state: SharePageState
        let attemptedPorts: [UInt16]
        let lastPortError: String?

        var diagnosticsSummary: String {
            "attemptedPorts=\(attemptedPorts), lastPortError=\(lastPortError ?? "none"), state=\(state.rawValue)"
        }
    }

    private func waitForHTTPStatus(
        url: URL,
        expected: Int,
        timeout: TimeInterval
    ) async -> Bool {
        await waitUntilAsync(timeout: timeout, pollInterval: .milliseconds(300)) {
            do {
                return try await self.fetchHTTPStatus(url: url, timeout: 2) == expected
            } catch {
                return false
            }
        }
    }

    private func waitForHTTPFailure(
        url: URL,
        timeout: TimeInterval
    ) async -> Bool {
        await waitUntilAsync(timeout: timeout, pollInterval: .milliseconds(300)) {
            do {
                _ = try await self.fetchHTTPStatus(url: url, timeout: 2)
                return false
            } catch {
                return true
            }
        }
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

    private func waitUntilAsync(
        timeout: TimeInterval,
        pollInterval: Duration,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return await condition()
    }
}
