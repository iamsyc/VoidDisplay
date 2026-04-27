import Foundation

nonisolated struct SupportHistoryStore {
    private let historyFileURL: URL
    private let exportsDirectoryURL: URL
    private let sanitizer: ObservabilitySanitizer
    private let fileManager: FileManager

    init(
        historyFileURL: URL,
        exportsDirectoryURL: URL,
        sanitizer: ObservabilitySanitizer = ObservabilitySanitizer(),
        fileManager: FileManager = .default
    ) {
        self.historyFileURL = historyFileURL
        self.exportsDirectoryURL = exportsDirectoryURL
        self.sanitizer = sanitizer
        self.fileManager = fileManager
    }

    func loadRecords() -> [SupportExportRecord] {
        let fileExists = fileManager.fileExists(atPath: historyFileURL.path)
        let decodedRecords: [SupportExportRecord]
        if fileExists,
           let data = try? Data(contentsOf: historyFileURL),
           let records = try? ObservabilityCodec.decode([SupportExportRecord].self, from: data) {
            decodedRecords = records
        } else {
            decodedRecords = []
        }

        var filteredRecords = decodedRecords.filter { record in
            fileManager.fileExists(atPath: record.resolvedBundleURL.path)
        }
        filteredRecords.sort { $0.exportedAt > $1.exportedAt }
        filteredRecords = Array(filteredRecords.prefix(10))

        if filteredRecords.isEmpty,
           let fallbackRecord = makeFallbackRecord() {
            filteredRecords = [fallbackRecord]
        }

        if fileExists == false || filteredRecords != decodedRecords {
            saveRecords(filteredRecords)
        }
        return filteredRecords
    }

    func saveRecords(_ records: [SupportExportRecord]) {
        do {
            try fileManager.createDirectory(at: historyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try ObservabilityCodec.encode(records)
            try data.write(to: historyFileURL, options: [.atomic])
        } catch {}
    }

    func appendRecord(_ record: SupportExportRecord) -> [SupportExportRecord] {
        var records = loadRecords()
        records.removeAll { $0.bundleFileName == record.bundleFileName }
        records.insert(record, at: 0)
        records.sort { $0.exportedAt > $1.exportedAt }
        let trimmed = Array(records.prefix(10))
        saveRecords(trimmed)
        return trimmed
    }

    func markSummaryCopied(recordID: UUID, at date: Date) -> [SupportExportRecord] {
        mutateRecords(recordID: recordID) { $0.summaryCopiedAt = date }
    }

    func markRevealed(recordID: UUID, at date: Date) -> [SupportExportRecord] {
        mutateRecords(recordID: recordID) { $0.revealedAt = date }
    }

    private func mutateRecords(
        recordID: UUID,
        mutation: (inout SupportExportRecord) -> Void
    ) -> [SupportExportRecord] {
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            return records
        }
        mutation(&records[index])
        saveRecords(records)
        return records
    }

    private func makeFallbackRecord() -> SupportExportRecord? {
        guard let bundleURL = latestExportedBundleURL(),
              let displayInfo = SupportBundleDisplayInfo(url: bundleURL, sanitizer: sanitizer) else {
            return nil
        }
        let resourceValues = try? bundleURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let exportedAt = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
        return SupportExportRecord(
            exportedAt: exportedAt,
            issueType: .other,
            bundleFileName: displayInfo.displayName,
            sanitizedBundlePath: displayInfo.sanitizedFullPath,
            draftPreview: ""
        )
    }

    private func latestExportedBundleURL() -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: exportsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .filter {
                $0.pathExtension == "zip" &&
                    $0.lastPathComponent.hasPrefix("support-bundle-")
            }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }?
            .resolvingSymlinksInPath()
    }
}
