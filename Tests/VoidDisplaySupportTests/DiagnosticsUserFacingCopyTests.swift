import Foundation
import Testing

struct DiagnosticsUserFacingCopyTests {
    @Test func diagnosticsUserFacingCopyDoesNotExposeSurfaceTerminology() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scannedFiles = [
            repositoryRoot.appendingPathComponent("Sources/VoidDisplaySupport/Views/DiagnosticsView.swift"),
            repositoryRoot.appendingPathComponent("Apps/VoidDisplay/Resources/Localizable.xcstrings")
        ]
        let forbiddenFragments = [
            "Surface Count",
            "Surface 数量",
            "显示表面"
        ]

        for fileURL in scannedFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for fragment in forbiddenFragments {
                #expect(
                    content.contains(fragment) == false,
                    "Forbidden user-facing copy '\(fragment)' found in \(fileURL.path)"
                )
            }
        }
    }
}
