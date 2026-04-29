import VoidDisplayFoundation
import Foundation
package struct SystemSnapshotProvider: ObservabilitySnapshotProvider, Sendable {
    package nonisolated struct Snapshot: Codable, Equatable, Sendable {
        package let operatingSystemVersion: String
        package let localeIdentifier: String
        package let timeZoneIdentifier: String
        package let isRunningUnderXCTest: Bool
        package let isUITestRuntimeEnabled: Bool
    }

    package let key = "system"

    private let environment: [String: String]
    private let processInfoProvider: @Sendable () -> ProcessInfo
    private let localeProvider: @Sendable () -> Locale
    private let timeZoneProvider: @Sendable () -> TimeZone

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processInfoProvider: @escaping @Sendable () -> ProcessInfo = { .processInfo },
        localeProvider: @escaping @Sendable () -> Locale = { .autoupdatingCurrent },
        timeZoneProvider: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.environment = environment
        self.processInfoProvider = processInfoProvider
        self.localeProvider = localeProvider
        self.timeZoneProvider = timeZoneProvider
    }

    @MainActor
    package func makeSnapshot() -> Snapshot {
        let processInfo = processInfoProvider()
        return Snapshot(
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            localeIdentifier: localeProvider().identifier,
            timeZoneIdentifier: timeZoneProvider().identifier,
            isRunningUnderXCTest: environment[PersistenceContext.xCTestConfigurationEnvironmentKey] != nil,
            isUITestRuntimeEnabled: UITestRuntime.isEnabled
        )
    }
}
