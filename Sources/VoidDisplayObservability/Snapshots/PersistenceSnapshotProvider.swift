import VoidDisplayFoundation
import Foundation
package struct PersistenceSnapshotProvider: ObservabilitySnapshotProvider, Sendable {
    package nonisolated struct Snapshot: Codable, Equatable, Sendable {
        package let mode: String
        package let bundleIdentifier: String
        package let appSupportRootPath: String
        package let observabilityDirectoryPath: String
        package let currentStatePath: String
        package let healthSummaryPath: String
        package let issuesPath: String
        package let eventsDirectoryPath: String
        package let exportsDirectoryPath: String
        package let virtualDisplayConfigsPath: String
        package let displayShareMappingsPath: String
    }

    package let key = "persistence"

    private let mode: PersistenceMode
    private let bundleIdentifier: String
    private let appSupportRootURL: URL
    private let observabilityDirectoryURL: URL
    private let currentStateURL: URL
    private let healthSummaryURL: URL
    private let issuesURL: URL
    private let eventsDirectoryURL: URL
    private let exportsDirectoryURL: URL
    private let virtualDisplayConfigsURL: URL
    private let displayShareMappingsURL: URL

    package init(context: PersistenceContext) {
        mode = context.mode
        bundleIdentifier = context.bundleIdentifier
        appSupportRootURL = context.appSupportRootURL
        observabilityDirectoryURL = context.observabilityDirectoryURL
        currentStateURL = context.observabilityCurrentStateURL
        healthSummaryURL = context.observabilityHealthSummaryURL
        issuesURL = context.observabilityIssuesURL
        eventsDirectoryURL = context.observabilityEventsDirectoryURL
        exportsDirectoryURL = context.observabilityExportsDirectoryURL
        virtualDisplayConfigsURL = context.virtualDisplayConfigsURL
        displayShareMappingsURL = context.displayShareIDMappingsURL
    }

    @MainActor
    package func makeSnapshot() -> Snapshot {
        Snapshot(
            mode: Self.modeDescription(mode),
            bundleIdentifier: bundleIdentifier,
            appSupportRootPath: appSupportRootURL.path,
            observabilityDirectoryPath: observabilityDirectoryURL.path,
            currentStatePath: currentStateURL.path,
            healthSummaryPath: healthSummaryURL.path,
            issuesPath: issuesURL.path,
            eventsDirectoryPath: eventsDirectoryURL.path,
            exportsDirectoryPath: exportsDirectoryURL.path,
            virtualDisplayConfigsPath: virtualDisplayConfigsURL.path,
            displayShareMappingsPath: displayShareMappingsURL.path
        )
    }

    private static func modeDescription(_ mode: PersistenceMode) -> String {
        switch mode {
        case .production:
            "production"
        case .testIsolatedWritable:
            "test_isolated"
        }
    }
}
