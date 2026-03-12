import XCTest

final class CapturePreviewDiagnosticsTests: XCTestCase {
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
    func testCapturePreviewLayoutMatrix() throws {
        for testCase in diagnosticCases {
            XCTContext.runActivity(named: testCase.id) { _ in
                let app = launchCapturePreviewDiagnosticsApp(
                    sourceSize: testCase.sourceSize,
                    targetContentWidth: testCase.targetContentWidth
                )
                defer { app.terminate() }

                let preview = smokeElement(app, identifier: "capture_preview_content")
                let scalePicker = smokeElement(app, identifier: "capture_preview_scale_mode_picker")
                XCTAssertTrue(scalePicker.waitForExistence(timeout: 4))
                XCTAssertTrue(preview.waitForExistence(timeout: 4))

                let screenshot = preview.screenshot()
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "capture-preview-\(testCase.id)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}

private extension CapturePreviewDiagnosticsTests {
    @MainActor
    func launchCapturePreviewDiagnosticsApp(
        sourceSize: String,
        targetContentWidth: Int
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_MODE"] = "1"
        app.launchEnvironment["VOIDDISPLAY_TEST_ISOLATION_ID"] = UUID().uuidString
        app.launchEnvironment["VOIDDISPLAY_UI_TEST_SCENARIO"] = "capture_preview_diagnostics"
        app.launchEnvironment["VOIDDISPLAY_CAPTURE_PREVIEW_SOURCE_SIZE"] = sourceSize
        app.launchEnvironment["VOIDDISPLAY_CAPTURE_PREVIEW_TARGET_CONTENT_WIDTH"] = String(targetContentWidth)
        app.launch()
        return app
    }
}
