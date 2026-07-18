import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package nonisolated struct SupportHistoryStore {
    private let historyFileURL: URL
    private let fileManager: FileManager
    private let sanitizer: ObservabilitySanitizer

    package init(
        historyFileURL: URL,
        fileManager: FileManager = .default,
        sanitizer: ObservabilitySanitizer = ObservabilitySanitizer()
    ) {
        self.historyFileURL = historyFileURL
        self.fileManager = fileManager
        self.sanitizer = sanitizer
    }

    package func loadRecords() -> [SupportExportRecord] {
        let fileExists = fileManager.fileExists(atPath: historyFileURL.path)
        let decodedRecords: [SupportExportRecord]
        let didSanitizeRecords: Bool
        if fileExists,
           let data = try? Data(contentsOf: historyFileURL),
           let records = try? ObservabilityCodec.decode([SupportExportRecord].self, from: data) {
            decodedRecords = records.map { $0.sanitizingPreview(with: sanitizer) }
            didSanitizeRecords = decodedRecords != records
        } else {
            decodedRecords = []
            didSanitizeRecords = false
        }

        var filteredRecords = decodedRecords.filter { record in
            fileManager.fileExists(atPath: record.resolvedBundleURL.path)
        }
        filteredRecords.sort { $0.exportedAt > $1.exportedAt }
        filteredRecords = Array(filteredRecords.prefix(10))

        if fileExists == false || didSanitizeRecords || filteredRecords != decodedRecords {
            try? saveRecords(filteredRecords)
        }
        return filteredRecords
    }

    package func saveRecords(_ records: [SupportExportRecord]) throws {
        try fileManager.createDirectory(at: historyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let safeRecords = records.map { $0.sanitizingPreview(with: sanitizer) }
        let data = try ObservabilityCodec.encode(safeRecords)
        try data.write(to: historyFileURL, options: [.atomic])
    }

    package func appendRecord(_ record: SupportExportRecord) throws -> [SupportExportRecord] {
        var records = loadRecords()
        let safeRecord = record.sanitizingPreview(with: sanitizer)
        records.removeAll { $0.bundleFileName == safeRecord.bundleFileName }
        records.insert(safeRecord, at: 0)
        records.sort { $0.exportedAt > $1.exportedAt }
        let trimmed = Array(records.prefix(10))
        try saveRecords(trimmed)
        return trimmed
    }

    package func markSummaryCopied(recordID: UUID, at date: Date) throws -> [SupportExportRecord] {
        try mutateRecords(recordID: recordID) { $0.summaryCopiedAt = date }
    }

    package func markRevealed(recordID: UUID, at date: Date) throws -> [SupportExportRecord] {
        try mutateRecords(recordID: recordID) { $0.revealedAt = date }
    }

    private func mutateRecords(
        recordID: UUID,
        mutation: (inout SupportExportRecord) -> Void
    ) throws -> [SupportExportRecord] {
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            return records
        }
        mutation(&records[index])
        try saveRecords(records)
        return records
    }

}
