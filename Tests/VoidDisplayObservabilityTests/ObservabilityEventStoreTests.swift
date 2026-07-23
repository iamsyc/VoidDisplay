@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@Suite(.serialized)
struct ObservabilityEventStoreTests {
    @Test func appendTrimsRingBufferAndDeduplicatesByKey() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "event-store")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = EventStore(
            directoryURL: tempURL,
            inMemoryLimit: 3,
            deduplicationWindow: 60
        )

        let baseDate = Date(timeIntervalSince1970: 100)
        for offset in 0..<4 {
            try await store.append(
                ObservabilityEvent(
                    timestamp: baseDate.addingTimeInterval(Double(offset)),
                    severity: .info,
                    subsystem: .capture,
                    operation: "Load \(offset)",
                    message: "Message \(offset)",
                    deduplicationKey: "event-\(offset)"
                )
            )
        }
        try await store.append(
            ObservabilityEvent(
                timestamp: baseDate.addingTimeInterval(4),
                severity: .info,
                subsystem: .capture,
                operation: "Load 3",
                message: "Message 3",
                deduplicationKey: "event-3"
            )
        )

        let recent = await store.recentInMemoryEvents(limit: 10)

        #expect(recent.count == 3)
        #expect(recent.map(\.deduplicationKey) == ["event-1", "event-2", "event-3"])
    }

    @Test func pruneExpiredFilesRemovesEventsOlderThanRetentionWindow() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "event-store-prune")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = EventStore(
            directoryURL: tempURL,
            retentionDays: 7,
            dateProvider: { now }
        )

        let oldFile = tempURL.appendingPathComponent("events-20250101.ndjson")
        let newFile = tempURL.appendingPathComponent("events-20250108.ndjson")
        try "{}\n".write(to: oldFile, atomically: true, encoding: .utf8)
        try "{}\n".write(to: newFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-9 * 24 * 60 * 60)],
            ofItemAtPath: oldFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: newFile.path
        )

        try await store.pruneExpiredFiles()

        #expect(FileManager.default.fileExists(atPath: oldFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: newFile.path))
    }

    @Test func appendHandlesConcurrentWrites() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "event-store-concurrent")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = EventStore(
            directoryURL: tempURL,
            deduplicationWindow: 0
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await store.append(
                        ObservabilityEvent(
                            timestamp: Date(timeIntervalSince1970: Double(index)),
                            severity: .info,
                            subsystem: .sharing,
                            operation: "Write \(index)",
                            message: "Concurrent event \(index)",
                            deduplicationKey: "unique-\(index)"
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let persisted = try await store.recentEvents(limit: 100)
        #expect(persisted.count == 40)
    }

    @Test func persistedEventsReloadAcrossStoreInstancesWithMilliseconds() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "event-store-reload")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let timestamp = Date(timeIntervalSince1970: 1_000.123)
        let ids = try [
            #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")),
            #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        ]
        let writer = EventStore(directoryURL: tempURL)
        for (index, id) in ids.enumerated() {
            try await writer.append(
                ObservabilityEvent(
                    id: id,
                    timestamp: timestamp,
                    severity: .info,
                    subsystem: .displayRuntime,
                    operation: "Virtual display transaction",
                    message: "Virtual display transaction phase changed.",
                    metadata: ["phase": "phase-\(index)"]
                )
            )
        }

        let reader = EventStore(directoryURL: tempURL)
        let persisted = try await reader.recentEvents(limit: 10)

        #expect(persisted.count == 2)
        #expect(persisted.map(\.id) == ids)
        #expect(persisted.allSatisfy { event in
            abs(event.timestamp.timeIntervalSince(timestamp)) < 0.001
        })
    }

    @Test func reloadsLegacyPrettyPrintedEventDocuments() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "event-store-legacy")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let events = (0..<2).map { index in
            ObservabilityEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                severity: .info,
                subsystem: .general,
                operation: "Legacy \(index)",
                message: "Legacy event \(index)."
            )
        }
        let legacyData = try events.reduce(into: Data()) { data, event in
            data.append(try ObservabilityCodec.encode(event))
            data.append(Data([0x0A]))
        }
        try legacyData.write(
            to: tempURL.appendingPathComponent("events-19700101.ndjson"),
            options: [.atomic]
        )

        let reader = EventStore(directoryURL: tempURL)
        let persisted = try await reader.recentEvents(limit: 10)

        #expect(persisted.map(\.operation) == ["Legacy 0", "Legacy 1"])
    }

    @Test func reloadSkipsTruncatedRecordAndRecoversAtNextNDJSONLine() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "event-store-recovery")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let validEvent = ObservabilityEvent(
            timestamp: Date(timeIntervalSince1970: 1_000.123),
            severity: .notice,
            subsystem: .observability,
            operation: "Recovered",
            message: "Valid event after a truncated record."
        )
        let writer = EventStore(directoryURL: tempURL)
        try await writer.append(validEvent)
        let fileURL = tempURL.appendingPathComponent("events-19700101.ndjson")
        let validData = try Data(contentsOf: fileURL)
        var data = Data(#"{"id":"truncated""#.utf8)
        data.append(Data([0x0A]))
        data.append(validData)
        try data.write(
            to: fileURL,
            options: [.atomic]
        )

        let reader = EventStore(directoryURL: tempURL)
        let persisted = try await reader.recentEvents(limit: 10)

        #expect(persisted == [validEvent])
    }

    @Test func snapshotReturnsRecentEvidenceAndCompleteFilteredWindowSummary() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "event-store-snapshot")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 4_000_000)
        let store = EventStore(
            directoryURL: tempURL,
            deduplicationWindow: 0,
            dateProvider: { now }
        )
        try await store.append(
            ObservabilityEvent(
                timestamp: now.addingTimeInterval(-60),
                severity: .warning,
                subsystem: .capture,
                operation: "Capture display",
                message: "Capture is delayed."
            )
        )
        for index in 0..<3 {
            try await store.append(
                ObservabilityEvent(
                    timestamp: now.addingTimeInterval(Double(index)),
                    severity: .error,
                    subsystem: .support,
                    operation: "Support workflow \(index)",
                    message: "Support workflow failed."
                )
            )
        }

        let snapshot = try await store.snapshot(
            recentLimit: 2,
            summarySince: now.addingTimeInterval(-24 * 60 * 60),
            summaryExcludingSubsystems: [.support]
        )

        #expect(snapshot.recentEvents.count == 2)
        #expect(snapshot.windowSummary.eventCount == 1)
        #expect(snapshot.windowSummary.highestSeverity == .warning)
    }
}
