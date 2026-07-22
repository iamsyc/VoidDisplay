@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@Suite(.serialized)
struct IssueStoreTests {
    @Test func recentIssuesAppliesRequestedTimeWindow() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "issue-store-window")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = IssueStore(
            fileURL: tempURL.appendingPathComponent("issues.json"),
            dateProvider: { now }
        )
        await store.record(event: makeEvent(at: now.addingTimeInterval(-60 * 60), key: "recent"))
        await store.record(event: makeEvent(at: now.addingTimeInterval(-2 * 24 * 60 * 60), key: "older"))

        let retained = await store.recentIssues()
        let lastDay = await store.recentIssues(
            since: now.addingTimeInterval(-24 * 60 * 60)
        )

        #expect(retained.map(\.deduplicationKey) == ["recent", "older"])
        #expect(lastDay.map(\.deduplicationKey) == ["recent"])
    }

    @Test func loadingLegacyFilePrunesIssuesOutsideRetentionWindow() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "issue-store-retention")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 2_000_000)
        let fileURL = tempURL.appendingPathComponent("issues.json")
        let legacyIssues = [
            makeIssue(at: now.addingTimeInterval(-8 * 24 * 60 * 60), key: "expired"),
            makeIssue(at: now.addingTimeInterval(-6 * 24 * 60 * 60), key: "retained")
        ]
        try ObservabilityCodec.encode(legacyIssues).write(to: fileURL, options: [.atomic])

        let store = IssueStore(fileURL: fileURL, dateProvider: { now })
        let issues = await store.recentIssues()
        let persisted = try ObservabilityCodec.decode(
            [IssueRecord].self,
            from: Data(contentsOf: fileURL)
        )

        #expect(issues.map(\.deduplicationKey) == ["retained"])
        #expect(persisted.map(\.deduplicationKey) == ["retained"])
    }

    @Test func repeatedIssuePreservesIdentityAndIncrementsOccurrenceCount() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "issue-store-deduplication")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 3_000_000)
        let store = IssueStore(
            fileURL: tempURL.appendingPathComponent("issues.json"),
            dateProvider: { now }
        )
        await store.record(event: makeEvent(at: now.addingTimeInterval(-2), key: "same"))
        let first = try #require(await store.recentIssues().first)
        await store.record(event: makeEvent(at: now.addingTimeInterval(-1), key: "same"))
        let updated = try #require(await store.recentIssues().first)

        #expect(updated.id == first.id)
        #expect(updated.firstSeenAt == first.firstSeenAt)
        #expect(updated.occurrenceCount == 2)
        #expect(updated.lastSeenAt == now.addingTimeInterval(-1))
    }

    @Test func supportErrorsRemainEventsWithoutEnteringIssueStorage() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "issue-store-support")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 4_000_000)
        let store = IssueStore(
            fileURL: tempURL.appendingPathComponent("issues.json"),
            limit: 1,
            dateProvider: { now }
        )
        await store.record(
            event: ObservabilityEvent(
                timestamp: now,
                severity: .error,
                subsystem: .support,
                operation: "Export support bundle",
                message: "Support export failed.",
                deduplicationKey: "support-export"
            )
        )
        await store.record(event: makeEvent(at: now, key: "runtime"))

        let issues = await store.recentIssues()
        #expect(issues.map(\.deduplicationKey) == ["runtime"])
    }

    private func makeEvent(at date: Date, key: String) -> ObservabilityEvent {
        ObservabilityEvent(
            timestamp: date,
            severity: .error,
            subsystem: .capture,
            operation: "Capture display",
            message: "Capture failed.",
            deduplicationKey: key
        )
    }

    private func makeIssue(at date: Date, key: String) -> IssueRecord {
        IssueRecord(
            id: UUID(),
            deduplicationKey: key,
            subsystem: .capture,
            operation: "Capture display",
            message: "Capture failed.",
            firstSeenAt: date,
            lastSeenAt: date,
            occurrenceCount: 1,
            latestMetadata: [:]
        )
    }
}
