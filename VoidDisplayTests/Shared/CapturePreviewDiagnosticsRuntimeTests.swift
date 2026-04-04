import Foundation
import Testing
@testable import VoidDisplay

@Suite(.serialized)
struct CapturePreviewDiagnosticsRuntimeTests {
    @Test @MainActor func configurationParsesSourceSizeAndWidthOverride() {
        let configuration = CapturePreviewDiagnosticsRuntime.configuration(
            environment: [
                CapturePreviewDiagnosticsRuntime.sourceSizeEnvironmentKey: "3008x1692",
                CapturePreviewDiagnosticsRuntime.targetContentWidthEnvironmentKey: "1180",
                CapturePreviewDiagnosticsRuntime.scaleModeEnvironmentKey: "native"
            ]
        )

        #expect(configuration?.sourcePixelSize == CGSize(width: 3008, height: 1692))
        #expect(configuration?.targetContentWidth == 1180)
        #expect(configuration?.replayImageURL == nil)
        #expect(configuration?.initialScaleMode == .native)
    }

    @Test @MainActor func parsedSizeAcceptsMultipleSeparators() {
        #expect(
            CapturePreviewDiagnosticsRuntime.parsedSize(from: "2560×1600")
                == CGSize(width: 2560, height: 1600)
        )
        #expect(
            CapturePreviewDiagnosticsRuntime.parsedSize(from: "1080,1920")
                == CGSize(width: 1080, height: 1920)
        )
        #expect(CapturePreviewDiagnosticsRuntime.parsedSize(from: "bad-value") == nil)
    }

    @Test @MainActor func configurationIgnoresInvalidScaleMode() {
        let configuration = CapturePreviewDiagnosticsRuntime.configuration(
            environment: [
                CapturePreviewDiagnosticsRuntime.scaleModeEnvironmentKey: "stretch"
            ]
        )

        #expect(configuration?.initialScaleMode == nil)
    }
}
