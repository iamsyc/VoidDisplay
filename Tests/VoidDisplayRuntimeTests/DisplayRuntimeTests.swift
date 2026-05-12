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

        #expect(snapshot.schemaVersion == 2)
        #expect(snapshot.surfaces.isEmpty)
        #expect(snapshot.catalog == .empty)
        #expect(snapshot.capture == .empty)
        #expect(snapshot.sharing == .empty)
        #expect(snapshot.virtualDisplay == .empty)
        #expect(snapshot.transactions == .empty)
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

    @Test func rebuildTransactionQuiescesSessionsBeforeVirtualDisplayCommand() async throws {
        let configID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let sessionID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let recorder = RuntimeOperationRecorder()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 77, isMain: false)),
            captureProvider: FakeCaptureProvider(
                snapshot: .init(
                    startingDisplayIDs: [],
                    sessions: [
                        .init(
                            id: sessionID,
                            displayID: 77,
                            isVirtualDisplay: true,
                            capturesCursor: true,
                            state: .active,
                            metrics: .empty
                        )
                    ]
                )
            ),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 77)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 77)),
            catalogCommander: FakeCatalogCommander(recorder: recorder),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder)
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completed)
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "stopSharing:77",
            "removeMonitoring:77",
            "rebuild:\(configID.uuidString)"
        ])
        #expect(trace.preSnapshotEvidence?.captureSessions.map(\.id) == [sessionID])
        #expect(trace.preSnapshotEvidence?.sharingDisplayIDs == [77])
        #expect(trace.postSnapshotEvidence != nil)
        #expect(trace.pauseIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                displayID: 77,
                pauseSharing: true,
                pauseMonitoring: true
            )
        ])
    }

    @Test func rebuildTransactionWritesFailedTraceForMissingConfig() async throws {
        let missingConfigID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let commander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: .empty),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: missingConfigID, source: .editSaveAndRebuild)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(commander.rebuildCallCount == 0)
        #expect(trace.status == .failed)
        #expect(trace.failure?.reason == "config_not_found")
        #expect(trace.preSnapshotEvidence != nil)
        #expect(trace.postSnapshotEvidence != nil)
    }

    @Test func rebuildTransactionCoalescesDuplicateRequestForSameConfig() async throws {
        let configID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 150_000_000)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 88)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander
        )

        async let first = runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        async let second = runtime.rebuildVirtualDisplay(configID: configID, source: .editSaveAndRebuild)
        let results = try await [first, second]
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(results.map(\.transactionID).first == results.map(\.transactionID).last)
        #expect(commander.rebuildCallCount == 1)
        #expect(trace.coalescedRequestCount == 1)
        #expect(trace.phases.contains(.init(phase: .queued, note: "coalesced_duplicate_request")))
    }

    @Test func rebuildTransactionEscalatesManagedMainToFleetScope() async throws {
        let targetConfigID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let peerConfigID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
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
                        .init(displayID: 91, pixelWidth: 1920, pixelHeight: 1080),
                        .init(displayID: 92, pixelWidth: 1920, pixelHeight: 1080)
                    ],
                    topologySignature: [
                        .init(
                            displayID: 91,
                            isMain: true,
                            pixelWidth: 1920,
                            pixelHeight: 1080,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        ),
                        .init(
                            displayID: 92,
                            isMain: false,
                            pixelWidth: 1920,
                            pixelHeight: 1080,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        )
                    ]
                )
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(
                    configs: [
                        (targetConfigID, 9101, 91),
                        (peerConfigID, 9102, 92)
                    ]
                )
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: FakeVirtualDisplayCommander()
        )

        _ = try await runtime.rebuildVirtualDisplay(configID: targetConfigID, source: .virtualDisplayRowRetry)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        let affectedConfigIDs = trace.affectedSurfaces.map(\.configID).sorted { $0.uuidString < $1.uuidString }
        let expectedConfigIDs = [targetConfigID, peerConfigID].sorted { $0.uuidString < $1.uuidString }
        #expect(affectedConfigIDs == expectedConfigIDs)
        #expect(trace.affectedSurfaces.contains { $0.reason == .managedMainFleetPeer && $0.configID == peerConfigID })
    }

    @Test func rebuildTransactionCallsCommandWhenPreDisplayIDIsUnavailable() async throws {
        let configID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let commander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
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
                            id: configID,
                            serialNumber: 9103,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completed)
        #expect(commander.rebuildCallCount == 1)
        #expect(trace.affectedSurfaces.first?.preDisplayID == nil)
        #expect(trace.pauseIntents.isEmpty)
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

private func catalogSnapshot(displayID: DisplayRuntimeDisplayID, isMain: Bool) -> DisplayRuntimeCatalogSnapshot {
    .init(
        hasScreenCapturePermission: true,
        lastPreflightPermission: true,
        lastRequestPermission: nil,
        isLoadingDisplays: false,
        hasLoadError: false,
        lastLoadError: nil,
        loadedDisplays: [.init(displayID: displayID, pixelWidth: 1920, pixelHeight: 1080)],
        topologySignature: [
            .init(
                displayID: displayID,
                isMain: isMain,
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshRateMilliHertz: 60_000,
                mirrorsDisplayID: nil
            )
        ]
    )
}

private func activeSharingSnapshot(displayID: DisplayRuntimeDisplayID) -> DisplayRuntimeSharingSnapshot {
    .init(
        activeSharingDisplayIDs: [displayID],
        startingDisplayIDs: [],
        isSharing: true,
        isWebServiceRunning: true,
        preferredPort: 8089,
        sharingClientCount: 1,
        sharingClientCounts: [.init(displayID: displayID, count: 1)],
        lifecycle: .init(
            phase: .running,
            requestedPort: 8089,
            boundPort: 8089,
            failureReason: nil,
            hasFailureMessage: false
        ),
        routes: [.init(displayID: displayID, hasConcreteRoute: true)]
    )
}

private func virtualDisplaySnapshot(
    configID: UUID,
    displayID: DisplayRuntimeDisplayID
) -> DisplayRuntimeVirtualDisplaySnapshot {
    virtualDisplaySnapshot(configs: [(configID, 9001, displayID)])
}

private func virtualDisplaySnapshot(
    configs: [(UUID, UInt32, DisplayRuntimeDisplayID)]
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        rebuildRequestCount: 0,
        rebuildingConfigIDs: [],
        runningConfigIDs: configs.map(\.0),
        recentlyAppliedConfigIDs: [],
        rebuildFailureConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: configs.map {
            .init(configID: $0.0, serialNumber: $0.1, displayID: $0.2, isLiveRuntime: true)
        },
        configs: configs.map {
            .init(
                id: $0.0,
                serialNumber: $0.1,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        },
        restoreFailureConfigIDs: []
    )
}

@MainActor
private final class RuntimeOperationRecorder {
    var events: [String] = []

    func append(_ event: String) {
        events.append(event)
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

@MainActor
private final class FakeCatalogCommander: DisplayRuntimeCatalogCommanding {
    private let recorder: RuntimeOperationRecorder?

    init(recorder: RuntimeOperationRecorder? = nil) {
        self.recorder = recorder
    }

    func requestPermission() -> Bool {
        true
    }

    func refreshPermission() -> Bool {
        true
    }

    func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope _: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult {
        recorder?.append("refresh:\(intent.rawValue)")
        return .reusedSnapshot
    }

    func clearSnapshotForDeniedPermission(loadErrorMessage _: String?) async {}

    func cancelRefresh(ownerScope _: DisplayRuntimeCatalogRefreshOwnerScope?) async {}

    func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay] {
        []
    }
}

@MainActor
private final class FakeSharingCommander: DisplayRuntimeSharingCommanding {
    private let recorder: RuntimeOperationRecorder?

    init(recorder: RuntimeOperationRecorder? = nil) {
        self.recorder = recorder
    }

    func registerShareableDisplays(_: [DisplayRuntimeShareableDisplayRegistration]) {}

    func stopSharing(displayID: DisplayRuntimeDisplayID) {
        recorder?.append("stopSharing:\(displayID)")
    }
}

@MainActor
private final class FakeCaptureCommander: DisplayRuntimeCaptureCommanding {
    private let recorder: RuntimeOperationRecorder?

    init(recorder: RuntimeOperationRecorder? = nil) {
        self.recorder = recorder
    }

    func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID) {
        recorder?.append("removeMonitoring:\(displayID)")
    }
}

@MainActor
private final class FakeVirtualDisplayCommander: DisplayRuntimeVirtualDisplayCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let delayNanoseconds: UInt64
    var rebuildCallCount = 0
    var rebuildConfigIDs: [UUID] = []
    var error: Error?

    init(
        recorder: RuntimeOperationRecorder? = nil,
        delayNanoseconds: UInt64 = 0
    ) {
        self.recorder = recorder
        self.delayNanoseconds = delayNanoseconds
    }

    func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult {
        rebuildCallCount += 1
        rebuildConfigIDs.append(configID)
        recorder?.append("rebuild:\(configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error {
            throw error
        }
        return .init(
            configID: configID,
            preDisplayID: nil,
            postDisplayID: nil,
            runningConfigIDsAfterCommand: [configID],
            managedDisplaysAfterCommand: []
        )
    }
}
