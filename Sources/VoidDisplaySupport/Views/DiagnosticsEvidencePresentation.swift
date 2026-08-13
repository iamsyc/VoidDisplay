import Foundation
import VoidDisplayObservability
import VoidDisplayRuntime

enum DiagnosticsEvidencePresentation {
    private static let visibleEventGroupLimit = 12

    struct Evidence: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let sourceOrder: Int
        let operation: String
        let message: String
        let metadata: [String: String]
    }

    struct EventGroup: Identifiable, Equatable {
        let id: UUID
        let title: String
        let domainTitle: String
        let latestTimestamp: Date
        let severity: ObservabilitySeverity
        let transactionID: String?
        let evidence: [Evidence]

        var occurrenceCount: Int {
            evidence.count
        }
    }

    struct TransactionPhase: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let title: String
        let rawPhase: String?
        let operation: String
        let message: String
        let metadata: [String: String]
    }

    struct Issue: Identifiable, Equatable {
        let id: UUID
        let title: String
        let domainTitle: String
        let lastSeenAt: Date
        let occurrenceCount: Int
        let evidence: Evidence
    }

    static func eventGroups(from events: [ObservabilityEvent]) -> [EventGroup] {
        let sortedEvents = events.enumerated().sorted(by: eventComesBefore)
        var groups: [EventGroup] = []

        for (sourceOrder, event) in sortedEvents {
            let evidence = makeEvidence(event, sourceOrder: sourceOrder)
            let eventTransactionID = transactionID(for: event)
            if let index = groups.firstIndex(where: { group in
                guard let firstEvidence = group.evidence.first else { return false }
                return group.domainTitle == domainTitle(event.subsystem)
                    && firstEvidence.operation == event.operation
                    && firstEvidence.message == event.message
                    && group.transactionID == eventTransactionID
            }) {
                let existing = groups[index]
                groups[index] = EventGroup(
                    id: existing.id,
                    title: existing.title,
                    domainTitle: existing.domainTitle,
                    latestTimestamp: existing.latestTimestamp,
                    severity: max(existing.severity, event.severity),
                    transactionID: existing.transactionID,
                    evidence: existing.evidence + [evidence]
                )
            } else {
                groups.append(
                    EventGroup(
                        id: event.id,
                        title: operationTitle(
                            event.operation,
                            domain: event.subsystem,
                            fallbackKind: .event
                        ),
                        domainTitle: domainTitle(event.subsystem),
                        latestTimestamp: event.timestamp,
                        severity: event.severity,
                        transactionID: eventTransactionID,
                        evidence: [evidence]
                    )
                )
            }
        }

        return Array(groups.prefix(visibleEventGroupLimit))
    }

    static func transactionPhases(from evidence: [Evidence]) -> [TransactionPhase] {
        evidence
            .sorted(by: evidenceComesBefore)
            .map { item in
                let rawPhase = item.metadata[DisplayRuntimeTransactionObservability.phaseMetadataKey]
                return TransactionPhase(
                    id: item.id,
                    timestamp: item.timestamp,
                    title: transactionPhaseTitle(rawPhase),
                    rawPhase: rawPhase,
                    operation: item.operation,
                    message: item.message,
                    metadata: item.metadata.filter { key, _ in
                        key != DisplayRuntimeTransactionObservability.transactionIDMetadataKey
                    }
                )
            }
    }

    static func timestampText(
        _ timestamp: Date,
        locale: Locale = .current
    ) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .standard)
            .locale(locale)
            .secondFraction(.fractional(3))
        return timestamp.formatted(style)
    }

    static func timeText(
        _ timestamp: Date,
        locale: Locale = .current
    ) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .standard)
            .locale(locale)
            .secondFraction(.fractional(3))
        return timestamp.formatted(style)
    }

    static func issue(_ issue: IssueRecord) -> Issue {
        Issue(
            id: issue.id,
            title: operationTitle(issue.operation, domain: issue.subsystem, fallbackKind: .issue),
            domainTitle: domainTitle(issue.subsystem),
            lastSeenAt: issue.lastSeenAt,
            occurrenceCount: issue.occurrenceCount,
            evidence: Evidence(
                id: issue.id,
                timestamp: issue.lastSeenAt,
                sourceOrder: 0,
                operation: issue.operation,
                message: issue.message,
                metadata: issue.latestMetadata
            )
        )
    }

    static func domainTitle(_ domain: ObservabilityDomain) -> String {
        switch domain {
        case .general:
            String(localized: "General")
        case .capture:
            String(localized: "Capture")
        case .sharing:
            String(localized: "Sharing")
        case .virtualDisplay:
            String(localized: "Virtual Display")
        case .screenCatalog:
            String(localized: "Screen Catalog")
        case .displayRuntime:
            String(localized: "Display Runtime")
        case .persistence:
            String(localized: "Persistence")
        case .web:
            String(localized: "Web Service")
        case .observability:
            String(localized: "Observability")
        case .support:
            String(localized: "Support")
        }
    }

    private enum FallbackKind {
        case event
        case issue
    }

    private static func operationTitle(
        _ operation: String,
        domain: ObservabilityDomain,
        fallbackKind: FallbackKind
    ) -> String {
        switch operation {
        case "Clear denied screen capture snapshot":
            String(localized: "Clear denied screen capture snapshot")
        case "Close preview session":
            String(localized: "Close preview session")
        case "Create virtual display":
            String(localized: "Create virtual display")
        case "Delete virtual display":
            String(localized: "Delete virtual display")
        case "Disable virtual display":
            String(localized: "Disable virtual display")
        case "Enable virtual display":
            String(localized: "Enable virtual display")
        case "Export support bundle":
            String(localized: "Export Support Bundle")
        case "Load shared display id store":
            String(localized: "Load shared display ID store")
        case "Persist display share id mappings":
            String(localized: "Persist display share ID mappings")
        case "Persist shared display id store":
            String(localized: "Persist shared display ID store")
        case "Rebuild virtual display":
            String(localized: "Rebuild virtual display")
        case "Remove preview sessions":
            String(localized: "Remove preview sessions")
        case "Reset virtual display configurations":
            String(localized: "Reset virtual display configurations")
        case "Screen capture permission check":
            String(localized: "Screen capture permission check")
        case "Screen capture stream stopped":
            String(localized: "Screen capture stream stopped")
        case "Set primary virtual display":
            String(localized: "Set primary virtual display")
        case "Start preview":
            String(localized: "Start preview")
        case "Start relay process":
            String(localized: "Start relay process")
        case "Start sharing":
            String(localized: "Start sharing")
        case "Start web service":
            String(localized: "Start web service")
        case "Stop all sharing":
            String(localized: "Stop all sharing")
        case "Stop sharing":
            String(localized: "Stop Sharing")
        case "Stop web service":
            String(localized: "Stop web service")
        case "Update virtual display config":
            String(localized: "Update virtual display configuration")
        case "Virtual display transaction":
            String(localized: "Virtual display transaction")
        case "Web service lifecycle changed":
            String(localized: "Web service lifecycle changed")
        case let operation where operation.hasPrefix("Support workflow "):
            supportWorkflowTitle(operation)
        case "create directory":
            String(localized: "Create data directory")
        case "load":
            String(localized: "Load saved data")
        case "reset":
            String(localized: "Reset saved data")
        case "save":
            String(localized: "Save data")
        default:
            fallbackTitle(domain: domain, kind: fallbackKind)
        }
    }

    private static func supportWorkflowTitle(_ operation: String) -> String {
        switch operation.replacingOccurrences(of: "Support workflow ", with: "") {
        case "page_opened":
            String(localized: "Open Diagnostics")
        case "issue_type_changed":
            String(localized: "Change support issue type")
        case "validation_failed":
            String(localized: "Validate support details")
        case "export_started":
            String(localized: "Start support export")
        case "export_succeeded":
            String(localized: "Complete support export")
        case "export_failed":
            String(localized: "Support export failed")
        case "summary_copied":
            String(localized: "Copy support summary")
        case "bundle_revealed":
            String(localized: "Reveal support bundle")
        case "new_feedback":
            String(localized: "Start new support draft")
        case "history_summary_copied":
            String(localized: "Copy support history summary")
        case "history_bundle_revealed":
            String(localized: "Reveal support history bundle")
        default:
            String(localized: "Support activity")
        }
    }

    private static func fallbackTitle(domain: ObservabilityDomain, kind: FallbackKind) -> String {
        let format = switch kind {
        case .event:
            String(localized: "%@ event")
        case .issue:
            String(localized: "%@ issue")
        }
        return String(format: format, locale: .current, domainTitle(domain))
    }

    private static func makeEvidence(
        _ event: ObservabilityEvent,
        sourceOrder: Int
    ) -> Evidence {
        Evidence(
            id: event.id,
            timestamp: event.timestamp,
            sourceOrder: sourceOrder,
            operation: event.operation,
            message: event.message,
            metadata: event.metadata
        )
    }

    private static func transactionID(for event: ObservabilityEvent) -> String? {
        guard event.subsystem == .displayRuntime,
              event.operation == DisplayRuntimeTransactionObservability.operation,
              let transactionID = event.metadata[
                  DisplayRuntimeTransactionObservability.transactionIDMetadataKey
              ],
              transactionID.isEmpty == false else {
            return nil
        }
        return transactionID
    }

    private static func transactionPhaseTitle(_ phase: String?) -> String {
        switch phase {
        case "queued":
            String(localized: "Queued")
        case "preparing":
            String(localized: "Preparing")
        case "persistingConfig":
            String(localized: "Persisting configuration")
        case "compensatingPersistence":
            String(localized: "Compensating persistence")
        case "quiescingSessions":
            String(localized: "Quiescing sessions")
        case "executingVirtualDisplayCommand":
            String(localized: "Executing virtual display command")
        case "waitingForTopology":
            String(localized: "Waiting for topology")
        case "restoringSessions":
            String(localized: "Restoring sessions")
        case "completed":
            String(localized: "Completed")
        case "failed":
            String(localized: "Failed")
        case "cancelled":
            String(localized: "Cancelled")
        default:
            String(localized: "Unknown phase")
        }
    }

    private static func eventComesBefore(
        _ lhs: (offset: Int, element: ObservabilityEvent),
        _ rhs: (offset: Int, element: ObservabilityEvent)
    ) -> Bool {
        if lhs.element.timestamp != rhs.element.timestamp {
            return lhs.element.timestamp > rhs.element.timestamp
        }
        return lhs.offset > rhs.offset
    }

    private static func evidenceComesBefore(_ lhs: Evidence, _ rhs: Evidence) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }
}
