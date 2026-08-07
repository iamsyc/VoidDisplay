@testable import VoidDisplayObservability
@testable import VoidDisplaySupport
import Foundation
import Testing

@Suite
@MainActor
struct DiagnosticsEvidencePresentationTests {
    @Test func mapsEverySeverityToDistinctReadablePresentation() {
        let expectedTitles: [(ObservabilitySeverity, String)] = [
            (.debug, String(localized: "Debug")),
            (.info, String(localized: "Info")),
            (.notice, String(localized: "Notice")),
            (.warning, String(localized: "Warning")),
            (.error, String(localized: "Error")),
            (.critical, String(localized: "Critical"))
        ]

        let titles = ObservabilitySeverity.allCases.map(DiagnosticsPresentation.title(for:))
        let systemImages = ObservabilitySeverity.allCases.map(DiagnosticsPresentation.systemImage(for:))

        #expect(titles.count == Set(titles).count)
        #expect(systemImages.count == Set(systemImages).count)
        for (severity, expectedTitle) in expectedTitles {
            #expect(DiagnosticsPresentation.title(for: severity) == expectedTitle)
            #expect(DiagnosticsPresentation.systemImage(for: severity).isEmpty == false)
        }
    }

    @Test func groupsMatchingRecentEventsNewestFirstAndPreservesEvidence() throws {
        let olderID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
        let newerID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000102"))
        let otherID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000103"))
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let latestDate = Date(timeIntervalSince1970: 300)
        let events = [
            ObservabilityEvent(
                id: olderID,
                timestamp: olderDate,
                severity: .info,
                subsystem: .capture,
                operation: "Start preview",
                message: "Preview request completed.",
                metadata: ["displayID": "41"]
            ),
            ObservabilityEvent(
                id: newerID,
                timestamp: newerDate,
                severity: .warning,
                subsystem: .capture,
                operation: "Start preview",
                message: "Preview request completed.",
                metadata: ["displayID": "42"]
            ),
            ObservabilityEvent(
                id: otherID,
                timestamp: latestDate,
                severity: .notice,
                subsystem: .sharing,
                operation: "Start sharing",
                message: "Sharing request completed."
            )
        ]

        let groups = DiagnosticsEvidencePresentation.eventGroups(from: events)

        #expect(groups.count == 2)
        #expect(groups[0].latestTimestamp == latestDate)
        #expect(groups[1].occurrenceCount == 2)
        #expect(groups[1].severity == .warning)
        #expect(groups[1].evidence.map(\.id) == [newerID, olderID])
        #expect(groups[1].evidence.map(\.metadata) == [["displayID": "42"], ["displayID": "41"]])
    }

    @Test func separatesTransactionsAndBuildsChronologicalPhaseTimelines() throws {
        let preparingID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000201"))
        let completedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000202"))
        let otherID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000203"))
        let persistingID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000204"))
        let events = [
            ObservabilityEvent(
                id: completedID,
                timestamp: Date(timeIntervalSince1970: 100.456),
                severity: .info,
                subsystem: .displayRuntime,
                operation: "Virtual display transaction",
                message: "Virtual display transaction phase changed.",
                metadata: [
                    "transactionID": "transaction-a",
                    "phase": "completed"
                ]
            ),
            ObservabilityEvent(
                id: preparingID,
                timestamp: Date(timeIntervalSince1970: 100.123),
                severity: .info,
                subsystem: .displayRuntime,
                operation: "Virtual display transaction",
                message: "Virtual display transaction phase changed.",
                metadata: [
                    "transactionID": "transaction-a",
                    "phase": "preparing"
                ]
            ),
            ObservabilityEvent(
                id: persistingID,
                timestamp: Date(timeIntervalSince1970: 100.234),
                severity: .info,
                subsystem: .displayRuntime,
                operation: "Virtual display transaction",
                message: "Virtual display transaction phase changed.",
                metadata: [
                    "transactionID": "transaction-a",
                    "phase": "persistingConfig"
                ]
            ),
            ObservabilityEvent(
                id: otherID,
                timestamp: Date(timeIntervalSince1970: 100.789),
                severity: .warning,
                subsystem: .displayRuntime,
                operation: "Virtual display transaction",
                message: "Virtual display transaction phase changed.",
                metadata: [
                    "transactionID": "transaction-b",
                    "phase": "failed"
                ]
            )
        ]

        let groups = DiagnosticsEvidencePresentation.eventGroups(from: events)
        let transactionA = try #require(
            groups.first(where: { $0.transactionID == "transaction-a" })
        )
        let phases = DiagnosticsEvidencePresentation.transactionPhases(
            from: transactionA.evidence
        )

        #expect(groups.count == 2)
        #expect(transactionA.occurrenceCount == 3)
        #expect(phases.map(\.id) == [preparingID, persistingID, completedID])
        #expect(
            phases.map(\.title)
                == [
                    String(localized: "Preparing"),
                    String(localized: "Persisting configuration"),
                    String(localized: "Completed")
                ]
        )
        #expect(phases.map(\.rawPhase) == ["preparing", "persistingConfig", "completed"])
        #expect(phases.allSatisfy { phase in
            phase.operation == "Virtual display transaction"
                && phase.message == "Virtual display transaction phase changed."
        })
        #expect(
            phases.map(\.metadata)
                == [
                    ["phase": "preparing"],
                    ["phase": "persistingConfig"],
                    ["phase": "completed"]
                ]
        )
    }

    @Test func sameMillisecondTransactionPhasesPreserveSourceOrder() throws {
        let firstID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let timestamp = Date(timeIntervalSince1970: 100.123)
        let events = [
            ObservabilityEvent(
                id: firstID,
                timestamp: timestamp,
                severity: .info,
                subsystem: .displayRuntime,
                operation: "Virtual display transaction",
                message: "Virtual display transaction phase changed.",
                metadata: ["transactionID": "transaction-a", "phase": "preparing"]
            ),
            ObservabilityEvent(
                id: secondID,
                timestamp: timestamp,
                severity: .info,
                subsystem: .displayRuntime,
                operation: "Virtual display transaction",
                message: "Virtual display transaction phase changed.",
                metadata: ["transactionID": "transaction-a", "phase": "completed"]
            )
        ]

        let group = try #require(
            DiagnosticsEvidencePresentation.eventGroups(from: events).first
        )
        let phases = DiagnosticsEvidencePresentation.transactionPhases(
            from: group.evidence
        )

        #expect(phases.map(\.id) == [firstID, secondID])
        #expect(phases.map(\.rawPhase) == ["preparing", "completed"])
    }

    @Test func formatsEventTimestampsWithMilliseconds() {
        let timestamp = Date(timeIntervalSince1970: 1_000.123_456)
        let locale = Locale(identifier: "en_US")

        let fullTimestamp = DiagnosticsEvidencePresentation.timestampText(
            timestamp,
            locale: locale
        )
        let time = DiagnosticsEvidencePresentation.timeText(
            timestamp,
            locale: locale
        )

        #expect(fullTimestamp.contains("40.123"))
        #expect(time.contains("40.123"))
    }

    @Test func groupsAllMatchingEvidenceBeforeApplyingVisibleGroupLimit() {
        let events = (0..<20).map { index in
            ObservabilityEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                severity: .info,
                subsystem: .capture,
                operation: "Start preview",
                message: "Preview request completed.",
                metadata: ["index": String(index)]
            )
        }

        let groups = DiagnosticsEvidencePresentation.eventGroups(from: events)

        #expect(groups.count == 1)
        #expect(groups[0].occurrenceCount == 20)
        #expect(
            groups[0].evidence.compactMap { $0.metadata["index"] }
                == (0..<20).reversed().map { String($0) }
        )
    }

    @Test func limitsVisibleGroupsAfterGrouping() {
        let events = (0..<13).map { index in
            ObservabilityEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                severity: .info,
                subsystem: .capture,
                operation: "Start preview",
                message: "Preview request \(index) completed."
            )
        }

        let groups = DiagnosticsEvidencePresentation.eventGroups(from: events)

        #expect(groups.count == 12)
        #expect(groups.first?.latestTimestamp == Date(timeIntervalSince1970: 12))
        #expect(groups.last?.latestTimestamp == Date(timeIntervalSince1970: 1))
    }

    @Test func knownOperationUsesReadableTitle() {
        let event = ObservabilityEvent(
            severity: .info,
            subsystem: .capture,
            operation: "Start preview",
            message: "raw message"
        )

        let group = DiagnosticsEvidencePresentation.eventGroups(from: [event])[0]

        #expect(group.title == String(localized: "Start preview"))
        #expect(group.domainTitle == String(localized: "Capture"))
        #expect(group.evidence[0].message == "raw message")
    }

    @Test func unknownOperationFallsBackWithoutDiscardingRawFields() {
        let event = ObservabilityEvent(
            severity: .error,
            subsystem: .web,
            operation: "Unknown transport operation",
            message: "raw failure",
            metadata: ["phase": "upgrade"]
        )

        let group = DiagnosticsEvidencePresentation.eventGroups(from: [event])[0]

        #expect(group.title == String(format: String(localized: "%@ event"), String(localized: "Web Service")))
        #expect(group.evidence[0].operation == "Unknown transport operation")
        #expect(group.evidence[0].message == "raw failure")
        #expect(group.evidence[0].metadata == ["phase": "upgrade"])
    }
}
