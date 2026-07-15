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
}
