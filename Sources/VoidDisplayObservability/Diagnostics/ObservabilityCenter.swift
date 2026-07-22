import VoidDisplayFoundation
import Foundation
import OSLog
package actor ObservabilityCenter {
    private static let healthLookbackInterval: TimeInterval = 24 * 60 * 60
    private static let supportEvidenceLookbackInterval: TimeInterval = 7 * 24 * 60 * 60

    private let eventStore: EventStore
    private let issueStore: IssueStore
    private let snapshotWriter: AgentSnapshotWriter
    private let exporter: FeedbackBundleExporter
    private let observabilityDirectoryURL: URL
    private let sanitizer: ObservabilitySanitizer
    private let dateProvider: () -> Date

    private var snapshotProviders: [String: AnyObservabilitySnapshotProvider] = [:]
    private var latestStateSnapshot: ObservabilityStateSnapshot?
    private var latestHealthSummary: ObservabilityHealthSummary?
    private(set) var lastExportedBundleURL: URL?

    package init(
        eventStore: EventStore,
        issueStore: IssueStore,
        snapshotWriter: AgentSnapshotWriter,
        exporter: FeedbackBundleExporter,
        observabilityDirectoryURL: URL,
        sanitizer: ObservabilitySanitizer,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.eventStore = eventStore
        self.issueStore = issueStore
        self.snapshotWriter = snapshotWriter
        self.exporter = exporter
        self.observabilityDirectoryURL = observabilityDirectoryURL
        self.sanitizer = sanitizer
        self.dateProvider = dateProvider
        self.lastExportedBundleURL = exporter.latestExportedBundleURL()
    }

    package func registerSnapshotProvider(_ provider: AnyObservabilitySnapshotProvider) {
        snapshotProviders[provider.key] = provider
    }

    package func record(_ event: ObservabilityEvent) async {
        let sanitizedEvent = sanitizer.sanitize(event)
        writeOSLog(for: sanitizedEvent)
        try? await eventStore.append(sanitizedEvent)
        await issueStore.record(event: sanitizedEvent)
        await refreshSnapshot(reason: .eventRecorded)
    }

    package func record(
        error: any Error,
        subsystem: ObservabilityDomain,
        operation: String,
        context: ObservabilityContext
    ) async {
        let message = localizedMessage(for: error)
        let event = ObservabilityEvent(
            severity: context.severity,
            subsystem: subsystem,
            operation: operation,
            message: context.message ?? message,
            metadata: context.metadata,
            correlationID: context.correlationID,
            deduplicationKey: context.deduplicationKey
        )
        let sanitizedEvent = sanitizer.sanitize(event)
        writeOSLog(for: sanitizedEvent)
        try? await eventStore.append(sanitizedEvent)
        await issueStore.record(event: sanitizedEvent)
        await refreshSnapshot(reason: .eventRecorded)
    }

    package func refreshSnapshot(reason: SnapshotRefreshReason) async {
        let now = dateProvider()
        let healthCutoff = now.addingTimeInterval(-Self.healthLookbackInterval)
        let sections = await buildSnapshotSections()
        let issues = Array(
            await issueStore.recentIssues(limit: 100, since: healthCutoff)
                .filter { $0.subsystem != .support }
                .prefix(25)
        )
        let eventSnapshot: ObservabilityEventSnapshot
        if let persistedSnapshot = try? await eventStore.snapshot(
            recentLimit: 200,
            summarySince: healthCutoff,
            summaryExcludingSubsystems: [.support]
        ) {
            eventSnapshot = persistedSnapshot
        } else {
            eventSnapshot = await eventStore.inMemorySnapshot(
                recentLimit: 200,
                summarySince: healthCutoff,
                summaryExcludingSubsystems: [.support]
            )
        }
        let state = ObservabilityStateSnapshot(
            generatedAt: now,
            refreshReason: reason,
            app: makeAppInfo(),
            sections: sections
        )
        let health = ObservabilityHealthSummary(
            generatedAt: now,
            recentEventCount: eventSnapshot.windowSummary.eventCount,
            recentIssueCount: issues.count,
            highestSeverity: eventSnapshot.windowSummary.highestSeverity,
            subsystemIssueCounts: makeSubsystemIssueCounts(from: issues),
            recentIssueMessages: issues.prefix(5).map(\.message)
        )
        latestStateSnapshot = state
        latestHealthSummary = health
        await snapshotWriter.scheduleWrite(
            state: state,
            health: health,
            events: eventSnapshot.recentEvents
        )
    }

    package func exportBundle(
        draft: FeedbackDraft,
        consent: FeedbackConsent
    ) async throws -> URL {
        await refreshSnapshot(reason: .exportRequested)
        let state = latestStateSnapshot ?? makeFallbackState(reason: .exportRequested)
        let health = latestHealthSummary ?? makeFallbackHealth()
        let evidenceCutoff = dateProvider().addingTimeInterval(-Self.supportEvidenceLookbackInterval)
        let events: [ObservabilityEvent]
        do {
            events = try await eventStore.recentEvents(limit: 2_000, since: evidenceCutoff)
        } catch {
            events = await eventStore.recentInMemoryEvents(limit: 2_000, since: evidenceCutoff)
            AppLog.observability.warning("Persisted events were unavailable during support export; using in-memory events.")
        }
        do {
            try await snapshotWriter.flush(state: state, health: health, events: events)
        } catch {
            AppLog.observability.warning("Agent snapshot flush failed during support export; continuing with the in-memory snapshot.")
        }
        let issues = await issueStore.recentIssues(limit: 100)
        let bundleURL = try exporter.exportBundle(
            draft: draft,
            consent: consent,
            state: state,
            health: health,
            events: events,
            issues: issues
        )
        lastExportedBundleURL = bundleURL
        await record(
            ObservabilityEvent(
                severity: .notice,
                subsystem: .observability,
                operation: "Export support bundle",
                message: "Exported support bundle.",
                metadata: ["bundlePath": sanitizer.sanitize(fileURL: bundleURL)]
            )
        )
        return bundleURL
    }

    package func lastExportedBundleDisplayPath() -> String? {
        guard let lastExportedBundleURL else { return nil }
        return sanitizer.sanitize(fileURL: lastExportedBundleURL)
    }

    package func exportedBundleURL() -> URL? {
        lastExportedBundleURL
    }

    package func dataDirectoryURL() -> URL? {
        observabilityDirectoryURL
    }

    package func dataDirectoryDisplayPath() -> String? {
        sanitizer.sanitize(fileURL: observabilityDirectoryURL)
    }

    package func recentIssues(limit: Int = 25) async -> [IssueRecord] {
        await issueStore.recentIssues(limit: limit)
    }

    package func diagnosticsSnapshot(
        issueLimit: Int = 25,
        eventLimit: Int = 200
    ) async -> ObservabilityDiagnosticsSnapshot {
        let earliestDate = dateProvider().addingTimeInterval(-Self.healthLookbackInterval)
        let state = latestStateSnapshot ?? makeFallbackState(reason: .manualDiagnosticsRefresh)
        let health = latestHealthSummary ?? makeFallbackHealth()
        let issues = await issueStore.recentIssues(limit: issueLimit, since: earliestDate)
        let events = ((try? await eventStore.recentEvents(limit: eventLimit)) ?? [])
            .filter { $0.timestamp >= earliestDate }
        return ObservabilityDiagnosticsSnapshot(
            state: state,
            health: health,
            issues: issues,
            events: events,
            lastExportedBundleDisplayPath: lastExportedBundleDisplayPath()
        )
    }

    package func summaryText(
        for draft: FeedbackDraft,
        issueTypeLine: String? = nil
    ) async -> String {
        let trimmed = draft.trimmedPayload()
        let issues = await issueStore.recentIssues(limit: 5)
        var lines: [String] = []
        lines.append(issueTypeLine ?? "\(String(localized: "Issue Type")): \(trimmed.issueType.rawValue)")
        if !trimmed.happened.isEmpty {
            lines.append(String(localized: "What happened:"))
            lines.append(trimmed.happened)
        }
        if !trimmed.reproductionSteps.isEmpty {
            lines.append(String(localized: "Reproduction steps:"))
            lines.append(trimmed.reproductionSteps)
        }
        if !trimmed.expectedResult.isEmpty {
            lines.append(String(localized: "Expected result:"))
            lines.append(trimmed.expectedResult)
        }
        if !issues.isEmpty {
            lines.append(String(localized: "Recent issues:"))
            lines.append(contentsOf: issues.prefix(3).map { "\($0.subsystem.rawValue): \($0.message)" })
        }
        if let bundleFileName = lastExportedBundleURL?.lastPathComponent,
           !bundleFileName.isEmpty {
            lines.append("\(String(localized: "Support Package")): \(bundleFileName)")
        }
        return lines.joined(separator: "\n")
    }

    private func buildSnapshotSections() async -> [String: JSONValue] {
        var sections: [String: JSONValue] = [:]
        for key in snapshotProviders.keys.sorted() {
            guard let provider = snapshotProviders[key] else { continue }
            do {
                sections[key] = try await provider.makeSnapshot()
            } catch {
                sections[key] = .object([
                    "error": .string(sanitizer.sanitize(text: String(describing: error)) ?? "unknown")
                ])
            }
        }
        return ObservabilitySectionSanitizer(sanitizer: sanitizer).sanitize(sections)
    }

    private func makeAppInfo() -> ObservabilityStateSnapshot.AppInfo {
        let bundle = Bundle.main
        return .init(
            bundleIdentifier: bundle.bundleIdentifier ?? "com.developerchen.voiddisplay",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            build: bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "1",
            executablePath: sanitizer.sanitize(fileURL: bundle.bundleURL)
        )
    }

    private func makeSubsystemIssueCounts(from issues: [IssueRecord]) -> [ObservabilityHealthSummary.SubsystemIssueCount] {
        Dictionary(grouping: issues, by: \.subsystem)
            .map { key, value in
                ObservabilityHealthSummary.SubsystemIssueCount(subsystem: key, count: value.count)
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.subsystem.rawValue < rhs.subsystem.rawValue
                }
                return lhs.count > rhs.count
            }
    }

    private func writeOSLog(for event: ObservabilityEvent) {
        let logger = AppLog.logger(for: event.subsystem)
        switch event.severity {
        case .debug:
            logger.debug("\(event.operation, privacy: .public): \(event.message, privacy: .public)")
        case .info, .notice:
            logger.info("\(event.operation, privacy: .public): \(event.message, privacy: .public)")
        case .warning:
            logger.warning("\(event.operation, privacy: .public): \(event.message, privacy: .public)")
        case .error, .critical:
            logger.error("\(event.operation, privacy: .public): \(event.message, privacy: .public)")
        }
    }

    private func localizedMessage(for error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !localized.isEmpty {
            return localized
        }
        let nsError = error as NSError
        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }
        return String(describing: error)
    }

    private func makeFallbackState(reason: SnapshotRefreshReason) -> ObservabilityStateSnapshot {
        ObservabilityStateSnapshot(
            generatedAt: dateProvider(),
            refreshReason: reason,
            app: makeAppInfo(),
            sections: [:]
        )
    }

    private func makeFallbackHealth() -> ObservabilityHealthSummary {
        ObservabilityHealthSummary(
            generatedAt: dateProvider(),
            recentEventCount: 0,
            recentIssueCount: 0,
            highestSeverity: nil,
            subsystemIssueCounts: [],
            recentIssueMessages: []
        )
    }

    private func decodeSection<T: Decodable>(
        _ key: String,
        from state: ObservabilityStateSnapshot,
        as type: T.Type
    ) -> T? {
        guard let section = state.sections[key] else { return nil }
        return try? section.decode(type)
    }
}
