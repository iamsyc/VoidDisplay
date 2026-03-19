import XCTest

final class CapturePreviewDiagnosticsTests: XCTestCase {
    private enum PreviewScaleMode: String, CaseIterable {
        case fit
        case native

        var segmentLabel: String {
            switch self {
            case .fit:
                "Fit"
            case .native:
                "1:1"
            }
        }

        static func fromAccessibilityValue(_ rawValue: String) -> Self? {
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains("fit") {
                return .fit
            }
            if normalized.contains("native") || normalized.contains("1:1") {
                return .native
            }
            return nil
        }
    }

    private struct DiagnosticCase {
        let id: String
        let sourceSize: String
        let targetContentWidth: Int
    }

    private let diagnosticCases: [DiagnosticCase] = [
        .init(id: "macbook-16x10-compact", sourceSize: "2560x1600", targetContentWidth: 860),
        .init(id: "macbook-16x10-wide", sourceSize: "2560x1600", targetContentWidth: 1320),
        .init(id: "desktop-16x9-medium", sourceSize: "3008x1692", targetContentWidth: 1180),
        .init(id: "ultrawide-21x9-medium", sourceSize: "3440x1440", targetContentWidth: 1380),
        .init(id: "portrait-tall", sourceSize: "1080x1920", targetContentWidth: 520)
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCapturePreviewLayoutMatrixFit() throws {
        runLayoutMatrix(scaleMode: .fit)
    }

    @MainActor
    func testCapturePreviewLayoutMatrixNative() throws {
        runLayoutMatrix(scaleMode: .native)
    }
}

private extension CapturePreviewDiagnosticsTests {
    @MainActor
    private func runLayoutMatrix(scaleMode: PreviewScaleMode) {
        for testCase in diagnosticCases {
            XCTContext.runActivity(named: "\(testCase.id)-\(scaleMode.rawValue)") { _ in
                let app = launchCapturePreviewDiagnosticsApp(
                    sourceSize: testCase.sourceSize,
                    targetContentWidth: testCase.targetContentWidth,
                    scaleMode: scaleMode
                )
                defer { app.terminate() }

                let preview = smokeElement(app, identifier: "capture_preview_content")
                let scalePicker = smokeElement(app, identifier: "capture_preview_scale_mode_picker")
                XCTAssertTrue(scalePicker.waitForExistence(timeout: 4))
                XCTAssertTrue(preview.waitForExistence(timeout: 4))
                assertScaleModeSelection(
                    scalePicker: scalePicker,
                    expectedMode: scaleMode
                )

                let screenshot = preview.screenshot()
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "capture-preview-\(scaleMode.rawValue)-\(testCase.id)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    private func launchCapturePreviewDiagnosticsApp(
        sourceSize: String,
        targetContentWidth: Int,
        scaleMode: PreviewScaleMode
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_MODE"] = "1"
        app.launchEnvironment["VOIDDISPLAY_TEST_ISOLATION_ID"] = UUID().uuidString
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = "capture_preview_diagnostics"
        app.launchEnvironment["VOIDDISPLAY_CAPTURE_PREVIEW_SOURCE_SIZE"] = sourceSize
        app.launchEnvironment["VOIDDISPLAY_CAPTURE_PREVIEW_TARGET_CONTENT_WIDTH"] = String(targetContentWidth)
        app.launchEnvironment["VOIDDISPLAY_CAPTURE_PREVIEW_SCALE_MODE"] = scaleMode.rawValue
        app.launch()
        return app
    }

    @MainActor
    private func assertScaleModeSelection(
        scalePicker: XCUIElement,
        expectedMode: PreviewScaleMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualMode = selectedScaleMode(from: scalePicker)
        XCTAssertEqual(
            actualMode,
            expectedMode,
            """
            Scale mode mismatch. expected=\(expectedMode.rawValue), actual=\(actualMode?.rawValue ?? "nil"), \
            pickerValue=\(String(describing: scalePicker.value)), picker=\(scalePicker.debugDescription)
            """,
            file: file,
            line: line
        )
        guard let actualMode else { return }
        XCTContext.runActivity(
            named: "Scale mode assertion passed: expected=\(expectedMode.rawValue), actual=\(actualMode.rawValue)"
        ) { _ in }
    }

    @MainActor
    private func selectedScaleMode(from scalePicker: XCUIElement) -> PreviewScaleMode? {
        if let value = scalePicker.value {
            let text = String(describing: value)
            if let mode = PreviewScaleMode.fromAccessibilityValue(text) {
                return mode
            }
        }

        for mode in PreviewScaleMode.allCases {
            let labeledElements = scalePicker
                .descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", mode.segmentLabel))
                .allElementsBoundByIndex
            if labeledElements.contains(where: isAccessibilityElementSelected) {
                return mode
            }
        }
        return nil
    }

    @MainActor
    private func isAccessibilityElementSelected(_ element: XCUIElement) -> Bool {
        if element.isSelected {
            return true
        }
        guard let value = element.value else { return false }
        let normalized = String(describing: value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == "1" || normalized == "true" {
            return true
        }
        if normalized.contains("selected") || normalized.contains("on") {
            return true
        }
        return false
    }
}
