import Foundation

package extension ObservabilitySanitizer {
    func sanitize(_ draft: FeedbackDraft) -> FeedbackDraft {
        FeedbackDraft(
            issueType: draft.issueType,
            happened: sanitize(text: draft.happened) ?? "",
            reproductionSteps: sanitize(text: draft.reproductionSteps) ?? "",
            expectedResult: sanitize(text: draft.expectedResult) ?? ""
        )
    }

    func sanitize(_ state: ObservabilityStateSnapshot) -> ObservabilityStateSnapshot {
        ObservabilityStateSnapshot(
            generatedAt: state.generatedAt,
            refreshReason: state.refreshReason,
            app: .init(
                bundleIdentifier: state.app.bundleIdentifier,
                version: state.app.version,
                build: state.app.build,
                executablePath: sanitize(path: state.app.executablePath)
            ),
            sections: ObservabilitySectionSanitizer(sanitizer: self).sanitize(state.sections)
        )
    }

    func sanitize(_ health: ObservabilityHealthSummary) -> ObservabilityHealthSummary {
        ObservabilityHealthSummary(
            generatedAt: health.generatedAt,
            recentEventCount: health.recentEventCount,
            recentIssueCount: health.recentIssueCount,
            highestSeverity: health.highestSeverity,
            subsystemIssueCounts: health.subsystemIssueCounts,
            recentIssueMessages: health.recentIssueMessages.map { sanitize(text: $0) ?? $0 }
        )
    }

    func sanitize(_ event: ObservabilityEvent) -> ObservabilityEvent {
        ObservabilityEvent(
            id: event.id,
            timestamp: event.timestamp,
            severity: event.severity,
            subsystem: event.subsystem,
            operation: sanitize(text: event.operation) ?? event.operation,
            message: sanitize(text: event.message) ?? event.message,
            metadata: sanitize(metadata: event.metadata),
            correlationID: sanitize(text: event.correlationID),
            deduplicationKey: sanitize(text: event.deduplicationKey)
        )
    }

    func sanitize(_ issue: IssueRecord) -> IssueRecord {
        IssueRecord(
            id: issue.id,
            deduplicationKey: sanitize(text: issue.deduplicationKey) ?? issue.deduplicationKey,
            subsystem: issue.subsystem,
            operation: sanitize(text: issue.operation) ?? issue.operation,
            message: sanitize(text: issue.message) ?? issue.message,
            firstSeenAt: issue.firstSeenAt,
            lastSeenAt: issue.lastSeenAt,
            occurrenceCount: issue.occurrenceCount,
            latestMetadata: sanitize(metadata: issue.latestMetadata)
        )
    }
}
