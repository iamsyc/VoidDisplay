@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeTests {
    @Test func managedVirtualDisplayIdentityUsesConfigID() {
        let configID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    rebuildRequestCount: 1,
                    rebuildingConfigIDs: [configID],
                    runningConfigIDs: [configID],
                    recentlyAppliedConfigIDs: [],
                    rebuildFailureConfigIDs: [],
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
        #expect(surface?.managedVirtualDisplay?.isRebuilding == true)
        #expect(surface?.managedVirtualDisplay?.maximumPixelWidth == 3840)
        #expect(surface?.managedVirtualDisplay?.maximumPixelHeight == 2160)
    }

    @Test func physicalDisplayIsAuxiliarySurface() {
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
    }

    @Test func shareRouteDoesNotBecomeSurfaceIdentity() {
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

    @Test func runtimeSnapshotAggregatesPortStatesDeterministically() {
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
                    rebuildRequestCount: 0,
                    rebuildingConfigIDs: [],
                    runningConfigIDs: [configID],
                    recentlyAppliedConfigIDs: [configID],
                    rebuildFailureConfigIDs: [],
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

    @Test func surfacesAreSortedByKindAndIdentity() {
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
                    rebuildRequestCount: 0,
                    rebuildingConfigIDs: [],
                    runningConfigIDs: [],
                    recentlyAppliedConfigIDs: [],
                    rebuildFailureConfigIDs: [],
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

    @Test func unavailableProvidersProduceEmptySnapshot() {
        let snapshot = DisplayRuntime().makeSnapshot()

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.surfaces.isEmpty)
        #expect(snapshot.catalog == .empty)
        #expect(snapshot.capture == .empty)
        #expect(snapshot.sharing == .empty)
        #expect(snapshot.virtualDisplay == .empty)
    }

    @Test func duplicatePortEntriesConvergeWithoutDroppingSnapshot() throws {
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
                    rebuildRequestCount: 0,
                    rebuildingConfigIDs: [],
                    runningConfigIDs: [configID],
                    recentlyAppliedConfigIDs: [],
                    rebuildFailureConfigIDs: [],
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

    @Test func snapshotProviderUsesRuntimeKeyAndEncodesSnapshot() async throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: false,
                    lastPreflightPermission: false,
                    lastRequestPermission: false,
                    isLoadingDisplays: false,
                    hasLoadError: true,
                    lastLoadError: .init(
                        domain: "ScreenCapture",
                        code: 1,
                        hasDescription: true,
                        hasFailureReason: false,
                        hasRecoverySuggestion: false
                    ),
                    loadedDisplays: [],
                    topologySignature: []
                )
            )
        )
        let provider = DisplayRuntimeSnapshotProvider(runtime: runtime)
        let erased = AnyObservabilitySnapshotProvider(provider)

        let json = try await erased.makeSnapshot()
        let snapshot = try json.decode(DisplayRuntimeSnapshot.self)

        #expect(erased.key == "runtime")
        #expect(snapshot.catalog.hasScreenCapturePermission == false)
        #expect(snapshot.catalog.lastLoadError?.domain == "ScreenCapture")
    }

    @Test func observabilityCenterIncludesRuntimeSection() async throws {
        let isolationID = "display-runtime-\(UUID().uuidString)"
        let environment = [
            PersistenceContext.persistenceModeEnvironmentKey: PersistenceContext.testIsolatedModeValue,
            PersistenceContext.testIsolationIDEnvironmentKey: isolationID,
            PersistenceContext.xCTestConfigurationEnvironmentKey: "tests.xctest"
        ]
        let persistenceContext = PersistenceContext.resolve(environment: environment)
        defer { try? FileManager.default.removeItem(at: persistenceContext.appSupportRootURL) }

        let sanitizer = ObservabilitySanitizer()
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: persistenceContext.observabilityEventsDirectoryURL),
            issueStore: IssueStore(fileURL: persistenceContext.observabilityIssuesURL),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: persistenceContext.observabilityCurrentStateURL,
                healthSummaryURL: persistenceContext.observabilityHealthSummaryURL,
                recentEventsURL: persistenceContext.observabilityRecentEventsURL,
                debounceDuration: .zero
            ),
            exporter: FeedbackBundleExporter(
                exportsDirectoryURL: persistenceContext.observabilityExportsDirectoryURL,
                virtualDisplayConfigsURL: persistenceContext.virtualDisplayConfigsURL,
                displayShareMappingsURL: persistenceContext.displayShareIDMappingsURL,
                sanitizer: sanitizer
            ),
            transport: LocalExportTransport(),
            observabilityDirectoryURL: persistenceContext.observabilityDirectoryURL,
            sanitizer: sanitizer
        )
        let runtime = DisplayRuntime()

        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(DisplayRuntimeSnapshotProvider(runtime: runtime))
        )
        await observability.refreshSnapshot(reason: .manualDiagnosticsRefresh)
        let diagnostics = await observability.diagnosticsSnapshot()

        let runtimeSection = try #require(diagnostics.state.sections["runtime"])
        let snapshot = try runtimeSection.decode(DisplayRuntimeSnapshot.self)
        #expect(snapshot == .empty)
    }
}

@MainActor
private final class FakeCatalogProvider: DisplayRuntimeCatalogProviding {
    let snapshot: DisplayRuntimeCatalogSnapshot

    init(snapshot: DisplayRuntimeCatalogSnapshot) {
        self.snapshot = snapshot
    }

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        snapshot
    }
}

@MainActor
private final class FakeCaptureProvider: DisplayRuntimeCaptureProviding {
    let snapshot: DisplayRuntimeCaptureSnapshot

    init(snapshot: DisplayRuntimeCaptureSnapshot) {
        self.snapshot = snapshot
    }

    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        snapshot
    }
}

@MainActor
private final class FakeSharingProvider: DisplayRuntimeSharingProviding {
    let snapshot: DisplayRuntimeSharingSnapshot

    init(snapshot: DisplayRuntimeSharingSnapshot) {
        self.snapshot = snapshot
    }

    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        snapshot
    }
}

@MainActor
private final class FakeVirtualDisplayProvider: DisplayRuntimeVirtualDisplayProviding {
    let snapshot: DisplayRuntimeVirtualDisplaySnapshot

    init(snapshot: DisplayRuntimeVirtualDisplaySnapshot) {
        self.snapshot = snapshot
    }

    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        snapshot
    }
}
