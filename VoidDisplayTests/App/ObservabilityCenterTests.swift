import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct ObservabilityCenterTests {
    @Test func exportBundleSanitizesSectionsAndIncludesSystemAndPersistenceSnapshots() async throws {
        let isolationID = "observability-center-\(UUID().uuidString)"
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

        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(
                StaticSnapshotProvider(
                    key: "capture",
                    snapshot: CaptureSnapshotProvider.Snapshot(
                        startingDisplayIDs: [77],
                        sessions: [
                            .init(
                                id: UUID(),
                                displayID: 77,
                                displayName: "Studio Display",
                                resolutionText: "2560 × 1440",
                                isVirtualDisplay: false,
                                capturesCursor: true,
                                state: "active",
                                metrics: .init(
                                    currentProfile: "mixed",
                                    currentFrameRateTier: "60fps",
                                    receivedFrameCount: 42,
                                    profileReconfigurationCount: 3,
                                    cursorOverrideReconfigurationCount: 1
                                )
                            )
                        ]
                    )
                )
            )
        )
        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(
                StaticSnapshotProvider(
                    key: "virtualDisplay",
                    snapshot: VirtualDisplaySnapshotProvider.Snapshot(
                        rebuildRequestCount: 0,
                        rebuildingConfigIDs: [],
                        runningConfigIDs: [],
                        recentlyAppliedConfigIDs: [],
                        rebuildFailureMessages: [:],
                        configStoreHasLoadFailure: true,
                        configStoreLoadErrorMessage: "Open \(NSHomeDirectory())/Library/Application Support/VoidDisplay/log.txt",
                        configStoreDiagnosticsSummary: "Restore from http://192.168.0.8:8080/debug",
                        managedDisplays: [],
                        configs: [
                            .init(
                                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                displayName: "Editing Desk",
                                serialNumber: 9001,
                                desiredEnabled: true,
                                physicalWidthMillimeters: 600,
                                physicalHeightMillimeters: 340,
                                modes: [
                                    .init(
                                        width: 1920,
                                        height: 1080,
                                        refreshRate: 60,
                                        enableHiDPI: true
                                    )
                                ]
                            )
                        ],
                        restoreFailures: [
                            .init(
                                configID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                displayName: "Editing Desk",
                                message: "Restore failed at \(NSHomeDirectory())/Desktop via http://10.0.0.8:8080/rebuild"
                            )
                        ]
                    )
                )
            )
        )
        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(
                StaticSnapshotProvider(
                    key: "screenCatalog",
                    snapshot: RedactionSnapshot(
                        path: "\(NSHomeDirectory())/Library/Application Support/VoidDisplay/current-state.json",
                        url: "http://192.168.1.11:8080/display",
                        message: "See \(NSHomeDirectory())/Desktop/trace.log and connect to 10.0.0.8."
                    )
                )
            )
        )
        let systemSnapshot = SystemSnapshotProvider(
            environment: environment,
            localeProvider: { Locale(identifier: "en_US") },
            timeZoneProvider: { TimeZone(identifier: "Asia/Shanghai") ?? .current }
        ).makeSnapshot()
        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(
                StaticSnapshotProvider(key: "system", snapshot: systemSnapshot)
            )
        )
        let persistenceSnapshot = PersistenceSnapshotProvider(context: persistenceContext).makeSnapshot()
        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(
                StaticSnapshotProvider(key: "persistence", snapshot: persistenceSnapshot)
            )
        )

        let bundleURL = try await observability.exportBundle(
            draft: FeedbackDraft(happened: "Black screen"),
            consent: FeedbackConsent()
        )
        let state = try decodeArchiveEntry(
            ObservabilityStateSnapshot.self,
            relativePathSuffix: "/state/current-state.json",
            archiveURL: bundleURL
        )

        let captureSection = try #require(state.sections["capture"])
        let capture = try captureSection.decode(CaptureSnapshotProvider.Snapshot.self)
        #expect(capture.sessions.count == 1)
        #expect(capture.sessions.first?.displayName == "Display 1")

        let virtualDisplaySection = try #require(state.sections["virtualDisplay"])
        let virtualDisplay = try virtualDisplaySection.decode(VirtualDisplaySnapshotProvider.Snapshot.self)
        #expect(virtualDisplay.configs.count == 1)
        #expect(virtualDisplay.configs.first?.displayName == "Virtual Display 1")
        #expect(virtualDisplay.restoreFailures.first?.displayName == "Virtual Display 1")
        #expect(virtualDisplay.configStoreLoadErrorMessage?.contains("~") == true)
        #expect(virtualDisplay.configStoreDiagnosticsSummary?.contains("<redacted-ip>") == true)
        #expect(virtualDisplay.restoreFailures.first?.message.contains("<redacted-ip>") == true)

        let systemSection = try #require(state.sections["system"])
        let system = try systemSection.decode(SystemSnapshotProvider.Snapshot.self)
        #expect(system.localeIdentifier == "en_US")
        #expect(system.timeZoneIdentifier == "Asia/Shanghai")
        #expect(system.isRunningUnderXCTest)
        #expect(system.isUITestRuntimeEnabled == UITestRuntime.isEnabled)
        #expect(system.operatingSystemVersion.isEmpty == false)

        let persistenceSection = try #require(state.sections["persistence"])
        let persistence = try persistenceSection.decode(PersistenceSnapshotProvider.Snapshot.self)
        #expect(persistence.mode == "test_isolated")
        #expect(persistence.bundleIdentifier.hasPrefix("com.developerchen.voiddisplay.tests."))
        #expect(persistence.bundleIdentifier.contains(String(isolationID.prefix(48))))
        #expect(persistence.appSupportRootPath.hasPrefix("~"))
        #expect(persistence.currentStatePath.hasPrefix("~"))
        #expect(persistence.exportsDirectoryPath.hasPrefix("~"))

        let redactionSection = try #require(state.sections["screenCatalog"])
        let redaction = try redactionSection.decode(RedactionSnapshot.self)
        #expect(redaction.path.hasPrefix("~"))
        #expect(redaction.url == "http://<redacted-ip>:8080/display")
        #expect(redaction.message.contains("~"))
        #expect(redaction.message.contains("<redacted-ip>"))
        #expect(redaction.message.contains(NSHomeDirectory()) == false)
        #expect(redaction.message.contains("10.0.0.8") == false)
    }

    @Test func exportBundlePersistsRecentEventsFileAndExposesDataDirectory() async throws {
        let isolationID = "observability-events-\(UUID().uuidString)"
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

        await observability.record(
            ObservabilityEvent(
                severity: .error,
                subsystem: .observability,
                operation: "Load support center",
                message: "Recent events file should be available.",
                metadata: ["directory": persistenceContext.observabilityDirectoryURL.path]
            )
        )

        _ = try await observability.exportBundle(
            draft: FeedbackDraft(happened: "Support center failed to load"),
            consent: FeedbackConsent()
        )

        let recentEventsContent = try String(
            contentsOf: persistenceContext.observabilityRecentEventsURL,
            encoding: .utf8
        )
        #expect(recentEventsContent.contains("Load support center"))

        let issuesData = try Data(contentsOf: persistenceContext.observabilityIssuesURL)
        let issues = try ObservabilityCodec.decode([IssueRecord].self, from: issuesData)
        #expect(issues.count == 1)
        #expect(issues.first?.message == "Recent events file should be available.")

        let dataDirectoryURL = await observability.dataDirectoryURL()
        #expect(dataDirectoryURL == persistenceContext.observabilityDirectoryURL)

        let dataDirectoryDisplayPath = await observability.dataDirectoryDisplayPath()
        #expect(dataDirectoryDisplayPath?.hasPrefix("~") == true)
    }

    @Test func summaryTextIncludesIssueTypeAndBundleFileName() async throws {
        let isolationID = "observability-summary-\(UUID().uuidString)"
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

        _ = try await observability.exportBundle(
            draft: FeedbackDraft(
                issueType: .blackScreen,
                happened: "Black screen after launch"
            ),
            consent: FeedbackConsent()
        )

        let summary = await observability.summaryText(
            for: FeedbackDraft(
                issueType: .blackScreen,
                happened: "Black screen after launch"
            )
        )

        #expect(
            summary.contains(
                String(localized: SupportIssueType.blackScreen.presentation.summaryPrefixKey)
            )
        )
        #expect(
            summary.contains("\(String(localized: "Support Package")): support-bundle-")
        )
        #expect(summary.contains(persistenceContext.observabilityExportsDirectoryURL.path) == false)
    }
}

private struct StaticSnapshotProvider<Snapshot: Codable & Sendable>: ObservabilitySnapshotProvider, Sendable {
    let key: String
    let snapshot: Snapshot

    @MainActor
    func makeSnapshot() -> Snapshot {
        snapshot
    }
}

private struct RedactionSnapshot: Codable, Equatable, Sendable {
    let path: String
    let url: String
    let message: String
}

private func decodeArchiveEntry<T: Decodable>(
    _ type: T.Type,
    relativePathSuffix: String,
    archiveURL: URL
) throws -> T {
    let extractionURL = try makeTemporaryDirectory(prefix: "observability-center-extract")
    defer { try? FileManager.default.removeItem(at: extractionURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", archiveURL.path, extractionURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let bundleRoot = try FileManager.default.contentsOfDirectory(
        at: extractionURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).first
    let entryURL = bundleRoot?.appendingPathComponent(String(relativePathSuffix.dropFirst()))
    let data = try Data(contentsOf: try #require(entryURL))
    return try ObservabilityCodec.decode(type, from: data)
}
