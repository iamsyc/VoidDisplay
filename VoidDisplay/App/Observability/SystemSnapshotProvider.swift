import Foundation

struct SystemSnapshotProvider: ObservabilitySnapshotProvider, Sendable {
    nonisolated struct Snapshot: Codable, Equatable, Sendable {
        let operatingSystemVersion: String
        let localeIdentifier: String
        let timeZoneIdentifier: String
        let isRunningUnderXCTest: Bool
        let isUITestRuntimeEnabled: Bool
    }

    let key = "system"

    private let environment: [String: String]
    private let processInfoProvider: @Sendable () -> ProcessInfo
    private let localeProvider: @Sendable () -> Locale
    private let timeZoneProvider: @Sendable () -> TimeZone

    init(
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
    func makeSnapshot() -> Snapshot {
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
