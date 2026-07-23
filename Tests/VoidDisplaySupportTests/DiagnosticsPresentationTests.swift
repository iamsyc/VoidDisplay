@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
@testable import VoidDisplaySupport
import Foundation
import SwiftUI
import Testing

@Suite
@MainActor
struct DiagnosticsPresentationTests {
    @Test func recoveredHistoricalWarningKeepsCurrentHealthGreen() throws {
        let presentation = DiagnosticsPresentation(
            snapshot: try makeDiagnosticsSnapshot(
                runtime: .empty,
                recentIssueCount: 0,
                highestSeverity: .warning
            )
        )

        #expect(presentation.statusTitle == String(localized: "Looks Good"))
        #expect(presentation.statusSystemImage == "checkmark.circle")
        #expect(presentation.statusTint == .green)
    }

    @Test func currentRuntimePermissionFailureUsesWarningPresentation() throws {
        let runtime = DisplayRuntimeSnapshot(
            surfaces: [],
            catalog: DisplayRuntimeCatalogSnapshot(
                hasScreenCapturePermission: false,
                lastPreflightPermission: false,
                lastRequestPermission: false,
                isLoadingDisplays: false,
                hasLoadError: false,
                lastLoadError: nil,
                loadedDisplays: [],
                topologySignature: []
            ),
            capture: .empty,
            sharing: .empty,
            virtualDisplay: .empty
        )
        let presentation = DiagnosticsPresentation(
            snapshot: try makeDiagnosticsSnapshot(
                runtime: runtime,
                recentIssueCount: 0,
                highestSeverity: .warning
            )
        )

        #expect(presentation.statusTitle == String(localized: "Diagnostics Warning"))
        #expect(presentation.statusSystemImage == "exclamationmark.triangle")
        #expect(presentation.statusTint == .orange)
    }

    @Test func recentIssueUsesWarningPresentation() throws {
        let presentation = DiagnosticsPresentation(
            snapshot: try makeDiagnosticsSnapshot(
                runtime: .empty,
                recentIssueCount: 1,
                highestSeverity: .error
            )
        )

        #expect(presentation.statusTitle == String(localized: "Recent Issues"))
        #expect(presentation.statusSystemImage == "exclamationmark.triangle")
        #expect(presentation.statusTint == .orange)
    }
}

private func makeDiagnosticsSnapshot(
    runtime: DisplayRuntimeSnapshot,
    recentIssueCount: Int,
    highestSeverity: ObservabilitySeverity?
) throws -> ObservabilityDiagnosticsSnapshot {
    let state = ObservabilityStateSnapshot(
        generatedAt: Date(timeIntervalSince1970: 100),
        refreshReason: .manualDiagnosticsRefresh,
        app: .init(
            bundleIdentifier: "com.developerchen.voiddisplay",
            version: "1.0.0",
            build: "1",
            executablePath: "~/Applications/VoidDisplay.app"
        ),
        sections: [
            "runtime": try ObservabilityCodec.decode(
                JSONValue.self,
                from: ObservabilityCodec.encode(runtime)
            )
        ]
    )
    let health = ObservabilityHealthSummary(
        generatedAt: Date(timeIntervalSince1970: 100),
        recentEventCount: highestSeverity == nil ? 0 : 1,
        recentIssueCount: recentIssueCount,
        highestSeverity: highestSeverity,
        subsystemIssueCounts: [],
        recentIssueMessages: []
    )
    return ObservabilityDiagnosticsSnapshot(
        state: state,
        health: health,
        issues: [],
        events: [],
        lastExportedBundleDisplayPath: nil
    )
}
