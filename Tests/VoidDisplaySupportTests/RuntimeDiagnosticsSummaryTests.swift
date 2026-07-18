@testable import VoidDisplaySupport
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

struct RuntimeDiagnosticsSummaryTests {
    @Test func summaryConsumesRuntimeSectionAsPrimaryDiagnosticsState() throws {
        let sensitiveFixtures = [
            "raw-share-id-fixture-5",
            "https://10.0.0.7:8080/display/raw-share-id-fixture-5",
            "10.0.0.7",
            "/Users/tester/Documents/private-session.txt",
            "Private Window Caption",
            "typed note body",
            "viewer-client-secret-5",
            "Desktop frame shows roadmap"
        ]
        let runtime = makeRuntimeSnapshot()
        let state = try makeState(
            sections: [
                "runtime": runtimeSection(runtime),
                "sharing": .object([
                    "legacySnapshot": .string(sensitiveFixtures.joined(separator: " | "))
                ])
            ]
        )

        let summary = RuntimeDiagnosticsSummary(state: state)

        #expect(summary.availability == .available)
        #expect(summary.isAvailable)
        #expect(summary.schemaVersion == 4)
        #expect(summary.surfaceCount == 1)
        #expect(summary.virtualDisplayCount == 0)
        #expect(summary.runningVirtualDisplayCount == 0)
        #expect(summary.physicalDisplayCount == 1)
        #expect(summary.totalConsumerLeaseCount == 1)
        #expect(summary.activeConsumerLeaseCount == 1)
        #expect(summary.aggregatedDemandCount == 1)
        #expect(summary.activeViewerCount == 2)
        #expect(summary.effectiveCaptureIntentCount == 1)
        #expect(summary.activeTransactionCount == 0)
        #expect(summary.recentTransactionCount == 1)
        #expect(summary.recentFailureCount == 1)
        #expect(summary.lastFailureCode == "runtime_rebuild_failed")

        let renderedSummary = [
            summary.statusCode,
            summary.schemaVersion.map(String.init) ?? "",
            "\(summary.surfaceCount)",
            "\(summary.virtualDisplayCount)",
            "\(summary.runningVirtualDisplayCount)",
            "\(summary.physicalDisplayCount)",
            "\(summary.totalConsumerLeaseCount)",
            "\(summary.activeConsumerLeaseCount)",
            "\(summary.aggregatedDemandCount)",
            "\(summary.activeViewerCount)",
            "\(summary.effectiveCaptureIntentCount)",
            "\(summary.activeTransactionCount)",
            "\(summary.recentTransactionCount)",
            "\(summary.recentFailureCount)",
            summary.lastFailureCode ?? ""
        ].joined(separator: "\n")
        for fixture in sensitiveFixtures {
            #expect(renderedSummary.contains(fixture) == false)
        }
    }

    @Test func summaryMarksRuntimeSectionMissingAsUnavailable() throws {
        let state = try makeState(sections: [
            "capture": .object(["sessions": .array([])])
        ])

        let summary = RuntimeDiagnosticsSummary(state: state)

        #expect(summary.availability == .unavailable(.runtimeSectionMissing))
        #expect(summary.isAvailable == false)
        #expect(summary.statusCode == "unavailable:runtime_section_missing")
        #expect(summary.schemaVersion == nil)
        #expect(summary.surfaceCount == 0)
        #expect(summary.virtualDisplayCount == 0)
        #expect(summary.runningVirtualDisplayCount == 0)
        #expect(summary.physicalDisplayCount == 0)
        #expect(summary.recentFailureCount == 0)
        #expect(summary.lastFailureCode == nil)
    }

    @Test func summarySeparatesVirtualRunningAndPhysicalDisplayCounts() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000301"))
        let state = try makeState(sections: [
            "runtime": runtimeSection(DisplayRuntimeSnapshot(
                surfaces: [
                    DisplaySurface(
                        identity: .managedVirtualDisplay(configID: configID),
                        kind: .managedVirtualDisplay,
                        currentDisplayID: 301,
                        isAuxiliary: false,
                        catalog: nil,
                        capture: nil,
                        sharing: nil,
                        managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState(
                            configID: configID,
                            serialNumber: 31,
                            desiredEnabled: true,
                            isRunning: true,
                            isLiveRuntime: true,
                            hasRestoreFailure: false,
                            modeCount: 1,
                            maximumPixelWidth: 1920,
                            maximumPixelHeight: 1080
                        )
                    ),
                    DisplaySurface(
                        identity: .physicalDisplay(displayID: 401),
                        kind: .physicalDisplay,
                        currentDisplayID: 401,
                        isAuxiliary: false,
                        catalog: nil,
                        capture: nil,
                        sharing: nil,
                        managedVirtualDisplay: nil
                    )
                ],
                catalog: .empty,
                capture: .empty,
                sharing: .empty,
                virtualDisplay: .empty
            ))
        ])

        let summary = RuntimeDiagnosticsSummary(state: state)

        #expect(summary.surfaceCount == 2)
        #expect(summary.virtualDisplayCount == 1)
        #expect(summary.runningVirtualDisplayCount == 1)
        #expect(summary.physicalDisplayCount == 1)
    }

    @Test func summaryCountsRecentRuntimeFailures() throws {
        let trace = DisplayRuntimeTransactionTrace(
            id: .init(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000401"))),
            kind: .virtualDisplayStartupRestore,
            source: .startup,
            status: .failed,
            phases: [.init(phase: .failed)],
            affectedSurfaces: [],
            preSnapshotEvidence: nil,
            postSnapshotEvidence: nil,
            pauseIntents: [],
            restoreIntents: [],
            restoreResults: [],
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "startup_restore_lower_command_failed",
                underlyingDomain: "CGVirtualDisplay",
                underlyingCode: -7,
                recoverability: .retryable
            ),
            compensation: .notRequired,
            coalescedRequestCount: 1
        )
        let state = try makeState(sections: [
            "runtime": runtimeSection(DisplayRuntimeSnapshot(
                surfaces: [],
                catalog: .empty,
                capture: .empty,
                sharing: .empty,
                virtualDisplay: .empty,
                transactions: .init(activeTransactions: [], recentTransactions: [trace])
            ))
        ])

        let summary = RuntimeDiagnosticsSummary(state: state)

        #expect(summary.recentFailureCount == 1)
        #expect(summary.lastFailureCode == "startup_restore_lower_command_failed")
    }

    @Test func summaryReportsNewestRecentRuntimeFailure() throws {
        let olderTrace = DisplayRuntimeTransactionTrace(
            id: .init(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000402"))),
            kind: .virtualDisplayStartupRestore,
            source: .startup,
            status: .failed,
            phases: [.init(phase: .failed)],
            affectedSurfaces: [],
            preSnapshotEvidence: nil,
            postSnapshotEvidence: nil,
            pauseIntents: [],
            restoreIntents: [],
            restoreResults: [],
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "older_startup_failure",
                recoverability: .retryable
            ),
            compensation: .notRequired,
            coalescedRequestCount: 1
        )
        let newerTrace = DisplayRuntimeTransactionTrace(
            id: .init(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000403"))),
            kind: .virtualDisplayStartupRestore,
            source: .startup,
            status: .failed,
            phases: [.init(phase: .failed)],
            affectedSurfaces: [],
            preSnapshotEvidence: nil,
            postSnapshotEvidence: nil,
            pauseIntents: [],
            restoreIntents: [],
            restoreResults: [],
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "newer_startup_failure",
                recoverability: .retryable
            ),
            compensation: .notRequired,
            coalescedRequestCount: 1
        )
        let state = try makeState(sections: [
            "runtime": runtimeSection(DisplayRuntimeSnapshot(
                surfaces: [],
                catalog: .empty,
                capture: .empty,
                sharing: .empty,
                virtualDisplay: .empty,
                transactions: .init(activeTransactions: [], recentTransactions: [newerTrace, olderTrace])
            ))
        ])

        let summary = RuntimeDiagnosticsSummary(state: state)

        #expect(summary.recentFailureCount == 2)
        #expect(summary.lastFailureCode == "newer_startup_failure")
    }

    @Test func summaryMarksRuntimeSectionDecodeFailureAsDegradedWithoutLeakingSectionValues() throws {
        let sensitiveFixtures = [
            "raw-share-id-fixture-9",
            "http://10.0.0.9:8080/display/raw-share-id-fixture-9",
            "10.0.0.9",
            "/Users/tester/Desktop/private-display.json",
            "Private Window Caption",
            "typed note body",
            "Desktop frame shows roadmap"
        ]
        let state = try makeState(sections: [
            "runtime": .object([
                "schemaVersion": .string(sensitiveFixtures.joined(separator: " | "))
            ])
        ])

        let summary = RuntimeDiagnosticsSummary(state: state)

        #expect(summary.availability == .degraded(.runtimeSectionDecodeFailed))
        #expect(summary.isAvailable == false)
        #expect(summary.statusCode == "degraded:runtime_section_decode_failed")
        #expect(summary.schemaVersion == nil)
        #expect(summary.surfaceCount == 0)
        #expect(summary.virtualDisplayCount == 0)
        #expect(summary.runningVirtualDisplayCount == 0)
        #expect(summary.physicalDisplayCount == 0)
        #expect(summary.recentFailureCount == 0)

        let renderedSummary = [
            summary.statusCode,
            summary.schemaVersion.map(String.init) ?? "",
            "\(summary.surfaceCount)",
            summary.lastFailureCode ?? ""
        ].joined(separator: "\n")
        for fixture in sensitiveFixtures {
            #expect(renderedSummary.contains(fixture) == false)
        }
    }
}

private func makeRuntimeSnapshot() -> DisplayRuntimeSnapshot {
    let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 77)
    let demand = DisplayRuntimeConsumerDemand(
        preferredFramesPerSecond: 30,
        capturesCursor: true,
        powerProfile: .automatic,
        latencyPreference: .realtime,
        activeViewerCount: 2
    )
    let lease = DisplayRuntimeConsumerLease(
        id: DisplayRuntimeConsumerLeaseID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!),
        surfaceIdentity: surfaceIdentity,
        surfaceEpoch: .initial,
        resolvedDisplayID: 77,
        kind: .lanWebView,
        owner: .init(source: .sharingService, redactedLabel: "viewer"),
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: Date(timeIntervalSince1970: 11),
        state: .attached,
        demand: demand,
        lastFailureCode: nil
    )
    let aggregate = DisplayRuntimeAggregatedDemand(
        surfaceIdentity: surfaceIdentity,
        surfaceEpoch: .initial,
        resolvedDisplayID: 77,
        activeLeaseIDs: [lease.id],
        consumerKinds: [.lanWebView],
        effectivePixelSize: .init(width: 1920, height: 1080),
        effectiveFramesPerSecond: 30,
        capturesCursor: true,
        qualityProfile: .lanWebViewOnly,
        powerProfile: .automatic,
        latencyPreference: .realtime,
        activeViewerCount: 2,
        permitsExplicitDowngrade: false
    )
    let revision = DisplayRuntimeCaptureIntentRevision(rawValue: 4)
    let intent = DisplayRuntimeCaptureIntent(
        surfaceIdentity: surfaceIdentity,
        surfaceEpoch: .initial,
        resolvedDisplayID: 77,
        aggregateDemand: aggregate,
        kind: .capture,
        reason: .attach,
        revision: revision
    )
    let trace = DisplayRuntimeTransactionTrace(
        id: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!),
        kind: .virtualDisplayRebuild,
        source: .diagnostics,
        status: .failed,
        phases: [.init(phase: .failed)],
        affectedSurfaces: [],
        preSnapshotEvidence: nil,
        postSnapshotEvidence: nil,
        pauseIntents: [],
        restoreIntents: [],
        restoreResults: [],
        failure: .init(
            phase: .executingVirtualDisplayCommand,
            reason: "runtime_rebuild_failed",
            recoverability: .retryable
        ),
        compensation: .notRequired,
        coalescedRequestCount: 1
    )
    return DisplayRuntimeSnapshot(
        surfaces: [
            DisplaySurface(
                identity: surfaceIdentity,
                kind: .physicalDisplay,
                currentDisplayID: 77,
                isAuxiliary: false,
                catalog: nil,
                capture: nil,
                sharing: .init(
                    displayID: 77,
                    isStarting: false,
                    isActive: true,
                    viewerCount: 2,
                    hasRoute: true
                ),
                managedVirtualDisplay: nil
            )
        ],
        catalog: .empty,
        capture: .empty,
        sharing: .empty,
        virtualDisplay: .empty,
        transactions: .init(activeTransactions: [], recentTransactions: [trace]),
        consumerLeases: [.init(lease: lease)],
        aggregatedDemands: [aggregate],
        effectiveCaptureIntents: [
            .init(
                intent: intent,
                lastApplyResult: .applied(revision: revision),
                lastFailureCode: nil
            )
        ],
        latestCaptureIntentRevision: revision
    )
}

private func runtimeSection(_ runtime: DisplayRuntimeSnapshot) throws -> JSONValue {
    try ObservabilityCodec.decode(JSONValue.self, from: ObservabilityCodec.encode(runtime))
}

private func makeState(sections: [String: JSONValue]) throws -> ObservabilityStateSnapshot {
    ObservabilityStateSnapshot(
        generatedAt: Date(timeIntervalSince1970: 10),
        refreshReason: .manualDiagnosticsRefresh,
        app: .init(
            bundleIdentifier: "com.developerchen.voiddisplay",
            version: "1.0.0",
            build: "1",
            executablePath: "~/Applications/VoidDisplay.app"
        ),
        sections: sections
    )
}
