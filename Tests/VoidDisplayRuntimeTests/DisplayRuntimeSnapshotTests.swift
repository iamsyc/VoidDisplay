@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeSnapshotTests {
    @Test func managedVirtualDisplayIdentityUsesConfigID() async {
        let configID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    runningConfigIDs: [configID],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [
                        .init(configID: configID, serialNumber: 9001, displayID: 77, isLiveRuntime: true)
                    ],
                    configs: [
                        .init(
                            id: configID,
                            serialNumber: 9001,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)]
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            )
        )

        let snapshot = runtime.makeSnapshot()
        let surface = snapshot.surfaces.first

        #expect(surface?.identity == .managedVirtualDisplay(configID: configID))
        #expect(surface?.identity.stableID == configID.uuidString)
        #expect(surface?.currentDisplayID == 77)
        #expect(surface?.isAuxiliary == false)
        #expect(surface?.managedVirtualDisplay?.isRunning == true)
        #expect(surface?.managedVirtualDisplay?.maximumPixelWidth == 3840)
        #expect(surface?.managedVirtualDisplay?.maximumPixelHeight == 2160)
    }
    @Test func physicalDisplayIsAuxiliarySurface() async {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [.init(displayID: 200, pixelWidth: 2560, pixelHeight: 1440)],
                    topologySignature: [
                        .init(
                            displayID: 200,
                            isMain: true,
                            pixelWidth: 2560,
                            pixelHeight: 1440,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        )
                    ]
                )
            )
        )

        let surface = runtime.makeSnapshot().surfaces.first

        #expect(surface?.identity == .physicalDisplay(displayID: 200))
        #expect(surface?.kind == .physicalDisplay)
        #expect(surface?.isAuxiliary == true)
        #expect(surface?.catalog?.pixelWidth == 2560)
        #expect(surface?.catalog?.isMain == true)
        #expect(runtime.surfaceIdentityForDisplayID(200) == .physicalDisplay(displayID: 200))
        #expect(runtime.surfaceIdentityForDisplayID(201) == nil)
    }

    @Test func surfaceIdentityForDisplayIDResolvesManagedVirtualSurface() async {
        let configID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 77, isMain: false)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(configID: configID, displayID: 77)
            )
        )

        #expect(runtime.surfaceIdentityForDisplayID(77) == .managedVirtualDisplay(configID: configID))
        #expect(runtime.makeSnapshot().surfaces.map(\.identity) == [
            .managedVirtualDisplay(configID: configID)
        ])
    }

    @Test func shareRouteDoesNotBecomeSurfaceIdentity() async {
        let runtime = DisplayRuntime(
            sharingProvider: FakeSharingProvider(
                snapshot: .init(
                    activeSharingDisplayIDs: [77],
                    startingDisplayIDs: [],
                    isSharing: true,
                    isWebServiceRunning: true,
                    preferredPort: 8089,
                    sharingClientCount: 2,
                    sharingClientCounts: [.init(displayID: 77, count: 2)],
                    lifecycle: .init(
                        phase: .running,
                        requestedPort: 8089,
                        boundPort: 8089,
                        failureReason: nil,
                        hasFailureMessage: false
                    ),
                    routes: [.init(displayID: 77, hasConcreteRoute: true)]
                )
            )
        )

        let surface = runtime.makeSnapshot().surfaces.first

        #expect(surface?.identity == .physicalDisplay(displayID: 77))
        #expect(surface?.sharing?.hasRoute == true)
        #expect(surface?.sharing?.viewerCount == 2)
    }
    @Test func runtimeSnapshotAggregatesPortStatesDeterministically() async {
        let configID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: true,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [
                        .init(displayID: 200, pixelWidth: 2560, pixelHeight: 1440),
                        .init(displayID: 77, pixelWidth: 3840, pixelHeight: 2160)
                    ],
                    topologySignature: []
                )
            ),
            captureProvider: FakeCaptureProvider(
                snapshot: .init(
                    startingDisplayIDs: [200],
                    sessions: [
                        .init(
                            id: sessionID,
                            displayID: 77,
                            isVirtualDisplay: true,
                            capturesCursor: true,
                            state: .active,
                            metrics: .init(
                                currentProfile: "quality",
                                currentFrameRateTier: "60fps",
                                receivedFrameCount: 42,
                                profileReconfigurationCount: 1,
                                cursorOverrideReconfigurationCount: 2
                            )
                        )
                    ]
                )
            ),
            sharingProvider: FakeSharingProvider(
                snapshot: .init(
                    activeSharingDisplayIDs: [77],
                    startingDisplayIDs: [],
                    isSharing: true,
                    isWebServiceRunning: true,
                    preferredPort: 8089,
                    sharingClientCount: 1,
                    sharingClientCounts: [.init(displayID: 77, count: 1)],
                    lifecycle: .init(
                        phase: .running,
                        requestedPort: 8089,
                        boundPort: 8089,
                        failureReason: nil,
                        hasFailureMessage: false
                    ),
                    routes: [.init(displayID: 77, hasConcreteRoute: true)]
                )
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    runningConfigIDs: [configID],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [
                        .init(configID: configID, serialNumber: 9002, displayID: 77, isLiveRuntime: true)
                    ],
                    configs: [
                        .init(
                            id: configID,
                            serialNumber: 9002,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)]
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            )
        )

        let snapshot = runtime.makeSnapshot()

        #expect(snapshot.surfaces.map(\.identity) == [
            .managedVirtualDisplay(configID: configID),
            .physicalDisplay(displayID: 200)
        ])
        #expect(snapshot.surfaces.first?.capture?.sessionIDs == [sessionID])
        #expect(snapshot.surfaces.first?.capture?.receivedFrameCount == 42)
        #expect(snapshot.surfaces.first?.sharing?.viewerCount == 1)
        #expect(snapshot.surfaces.last?.capture?.isStarting == true)
    }
    @Test func surfacesAreSortedByKindAndIdentity() async {
        let firstConfigID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondConfigID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [
                        .init(displayID: 20, pixelWidth: 1920, pixelHeight: 1080),
                        .init(displayID: 10, pixelWidth: 1920, pixelHeight: 1080)
                    ],
                    topologySignature: []
                )
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    runningConfigIDs: [],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [],
                    configs: [
                        .init(
                            id: secondConfigID,
                            serialNumber: 9002,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: []
                        ),
                        .init(
                            id: firstConfigID,
                            serialNumber: 9001,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: []
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            )
        )

        #expect(runtime.makeSnapshot().surfaces.map(\.identity) == [
            .managedVirtualDisplay(configID: firstConfigID),
            .managedVirtualDisplay(configID: secondConfigID),
            .physicalDisplay(displayID: 10),
            .physicalDisplay(displayID: 20)
        ])
    }
    @Test func unavailableProvidersProduceEmptySnapshot() async {
        let snapshot = DisplayRuntime().makeSnapshot()

        #expect(snapshot.schemaVersion == 4)
        #expect(snapshot.surfaces.isEmpty)
        #expect(snapshot.catalog == .empty)
        #expect(snapshot.capture == .empty)
        #expect(snapshot.sharing == .empty)
        #expect(snapshot.virtualDisplay == .empty)
        #expect(snapshot.transactions == .empty)
    }

    @Test func runtimeSnapshotExcludesSensitiveFixtureValues() async throws {
        let displayID: DisplayRuntimeDisplayID = 731
        let sensitiveFixtures = runtimePrivacySensitiveFixtures()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: displayID, isMain: true)),
            captureProvider: FakeCaptureProvider(snapshot: previewCaptureSnapshot(displayID: displayID, capturesCursor: true)),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: displayID)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: .physicalDisplay(displayID: displayID),
            kind: .lanWebView,
            owner: .init(source: .sharingService, redactedLabel: sensitiveFixtures.joined(separator: " | ")),
            demand: consumerDemandSnapshotFixture(
                sourceWidth: 3840,
                sourceHeight: 2160,
                preferredWidth: 1920,
                preferredHeight: 1080,
                preferredFramesPerSecond: 30,
                capturesCursor: true,
                powerProfile: .smooth,
                activeViewerCount: 2
            )
        )

        let snapshot = runtime.makeSnapshot()
        let runtimeJSON = String(decoding: try ObservabilityCodec.encode(snapshot), as: UTF8.self)
        let decoded = try ObservabilityCodec.decode(
            DisplayRuntimeSnapshot.self,
            from: ObservabilityCodec.encode(snapshot)
        )

        #expect(snapshot.schemaVersion == 4)
        #expect(decoded.schemaVersion == 4)
        #expect(snapshot.sharing.routes.first?.hasConcreteRoute == true)
        #expect(snapshot.sharing.sharingClientCount == 1)
        #expect(snapshot.consumerLeases.first?.ownerSource == .sharingService)
        #expect(snapshot.aggregatedDemands.first?.activeViewerCount == 2)
        #expect(runtimeJSON.contains("redactedLabel") == false)
        for sensitiveFixture in sensitiveFixtures {
            #expect(runtimeJSON.contains(sensitiveFixture) == false)
        }
    }

    @Test func duplicatePortEntriesConvergeWithoutDroppingSnapshot() async throws {
        let configID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [
                        .init(displayID: 77, pixelWidth: 1920, pixelHeight: 1080),
                        .init(displayID: 77, pixelWidth: 1920, pixelHeight: 1080)
                    ],
                    topologySignature: [
                        .init(
                            displayID: 77,
                            isMain: false,
                            pixelWidth: 1920,
                            pixelHeight: 1080,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        ),
                        .init(
                            displayID: 77,
                            isMain: false,
                            pixelWidth: 1920,
                            pixelHeight: 1080,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        )
                    ]
                )
            ),
            sharingProvider: FakeSharingProvider(
                snapshot: .init(
                    activeSharingDisplayIDs: [77],
                    startingDisplayIDs: [],
                    isSharing: true,
                    isWebServiceRunning: true,
                    preferredPort: 8089,
                    sharingClientCount: 3,
                    sharingClientCounts: [
                        .init(displayID: 77, count: 1),
                        .init(displayID: 77, count: 2)
                    ],
                    lifecycle: .init(
                        phase: .running,
                        requestedPort: 8089,
                        boundPort: 8089,
                        failureReason: nil,
                        hasFailureMessage: false
                    ),
                    routes: [.init(displayID: 77, hasConcreteRoute: true)]
                )
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    runningConfigIDs: [configID],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [
                        .init(configID: configID, serialNumber: 9004, displayID: 77, isLiveRuntime: true),
                        .init(configID: configID, serialNumber: 9004, displayID: 77, isLiveRuntime: true)
                    ],
                    configs: [
                        .init(
                            id: configID,
                            serialNumber: 9004,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
                        ),
                        .init(
                            id: configID,
                            serialNumber: 9004,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            )
        )

        let snapshot = runtime.makeSnapshot()
        let surface = try #require(snapshot.surfaces.first)

        #expect(snapshot.surfaces.count == 1)
        #expect(surface.identity == .managedVirtualDisplay(configID: configID))
        #expect(surface.sharing?.viewerCount == 3)
        #expect(surface.catalog?.pixelWidth == 1920)
    }

    @Test func snapshotEncodesConsumerDemandAndEffectiveIntent() async throws {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 501)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 501, isMain: true)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )

        let previewLease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI, redactedLabel: "local preview"),
            demand: consumerDemandSnapshotFixture(
                sourceWidth: 2560,
                sourceHeight: 1440,
                capturesCursor: false
            )
        )
        let lanLease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService, redactedLabel: "lan view"),
            demand: consumerDemandSnapshotFixture(
                sourceWidth: 3840,
                sourceHeight: 2160,
                capturesCursor: true,
                powerProfile: .smooth,
                activeViewerCount: 3
            )
        )
        let latestRevision = try #require(runtime.currentLatestCaptureIntentRevision())
        let applyResult = runtime.recordCaptureIntentApplyResult(
            .init(revision: latestRevision, outcome: .applied)
        )

        let snapshot = runtime.makeSnapshot()
        let aggregate = try #require(snapshot.aggregatedDemands.first)
        let effectiveIntent = try #require(snapshot.effectiveCaptureIntents.first)
        let decoded = try ObservabilityCodec.decode(
            DisplayRuntimeSnapshot.self,
            from: ObservabilityCodec.encode(snapshot)
        )

        #expect(applyResult.outcome == .applied)
        #expect(snapshot.schemaVersion == 4)
        #expect(Set(snapshot.consumerLeases.map(\.id)) == Set([previewLease.id, lanLease.id]))
        #expect(Set(snapshot.consumerLeases.map(\.ownerSource)) == Set([.localUI, .sharingService]))
        #expect(snapshot.consumerLeases.map(\.state) == [.attached, .attached])
        #expect(Set(aggregate.activeLeaseIDs) == Set([previewLease.id, lanLease.id]))
        #expect(aggregate.qualityProfile == .mixed)
        #expect(aggregate.effectivePixelSize == .init(width: 3840, height: 2160))
        #expect(aggregate.effectiveFramesPerSecond == 60)
        #expect(aggregate.capturesCursor == true)
        #expect(aggregate.activeViewerCount == 3)
        #expect(effectiveIntent.intent.revision == latestRevision)
        #expect(effectiveIntent.intent.aggregateDemand == aggregate)
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
        #expect(snapshot.consumerSummary.activeLeaseCount == 2)
        #expect(snapshot.consumerSummary.totalLeaseCount == 2)
        #expect(snapshot.consumerSummary.activeViewerCount == 3)
        #expect(snapshot.consumerSummary.latestCaptureIntentRevision == latestRevision)
        #expect(snapshot.consumerSummary.surfaceEpochs.first?.surfaceEpoch == .initial)
        #expect(
            snapshot.consumerSummary.leaseCountsByKind.contains {
                $0.kind == .lanWebView && $0.activeCount == 1 && $0.totalCount == 1
            }
        )
        #expect(
            snapshot.consumerSummary.leaseCountsByKind.contains {
                $0.kind == .preview && $0.activeCount == 1 && $0.totalCount == 1
            }
        )
        #expect(Set(decoded.consumerLeases.map(\.id)) == Set([previewLease.id, lanLease.id]))
        #expect(decoded.aggregatedDemands.first?.activeViewerCount == 3)
        #expect(decoded.effectiveCaptureIntents.first?.intent.revision == latestRevision)
    }
}

private func consumerDemandSnapshotFixture(
    sourceWidth: Int,
    sourceHeight: Int,
    preferredWidth: Int? = nil,
    preferredHeight: Int? = nil,
    preferredFramesPerSecond: Int? = nil,
    capturesCursor: Bool,
    powerProfile: DisplayRuntimeCapturePowerProfile = .automatic,
    activeViewerCount: Int = 0
) -> DisplayRuntimeConsumerDemand {
    let preferredPixelSize: DisplayRuntimePixelSize?
    if let preferredWidth, let preferredHeight {
        preferredPixelSize = .init(width: preferredWidth, height: preferredHeight)
    } else {
        preferredPixelSize = nil
    }

    return DisplayRuntimeConsumerDemand(
        sourcePixelSize: .init(width: sourceWidth, height: sourceHeight),
        preferredPixelSize: preferredPixelSize,
        sourceFramesPerSecond: 60,
        preferredFramesPerSecond: preferredFramesPerSecond,
        capturesCursor: capturesCursor,
        powerProfile: powerProfile,
        latencyPreference: .realtime,
        activeViewerCount: activeViewerCount
    )
}

private func runtimePrivacySensitiveFixtures() -> [String] {
    [
        "share-id-raw-fixture-731",
        "https://192.168.73.10:8089/display/share-id-raw-fixture-731",
        "192.168.73.10",
        "\(NSHomeDirectory())/Documents/private-display-runtime-notes.txt",
        "Payroll Forecast - Private Window",
        "typed customer search text",
        "viewer-client-raw-id-731",
        "desktop shows confidential roadmap"
    ]
}
