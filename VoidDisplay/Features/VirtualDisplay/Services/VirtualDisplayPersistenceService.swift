import Foundation
import OSLog

protocol VirtualDisplayStoring {
    func load() throws -> [VirtualDisplayConfig]
    func save(_ configs: [VirtualDisplayConfig]) throws
    func reset() throws
}

extension VirtualDisplayStore: VirtualDisplayStoring {}

struct VirtualDisplayRestoreFailure: Identifiable, Equatable {
    let id: UUID
    let name: String
    let serialNum: UInt32
    let message: String
}

@MainActor
final class VirtualDisplayPersistenceService {
    typealias FailureReporter = (_ operation: String, _ error: Error) -> Void

    private let store: any VirtualDisplayStoring
    private let reportFailure: FailureReporter

    init(
        store: any VirtualDisplayStoring,
        reportFailure: FailureReporter? = nil
    ) {
        self.store = store
        self.reportFailure = reportFailure ?? { operation, error in
            AppErrorMapper.logFailure(operation, error: error, logger: AppLog.persistence)
        }
    }

    convenience init() {
        self.init(store: VirtualDisplayStore())
    }

    func loadConfigs() -> [VirtualDisplayConfig] {
        do {
            return try store.load()
        } catch {
            reportFailure("Load virtual display configs", error)
            return []
        }
    }

    func saveConfigs(_ configs: [VirtualDisplayConfig]) {
        do {
            try store.save(configs)
        } catch {
            reportFailure("Save virtual display configs", error)
        }
    }

    func resetConfigs() {
        do {
            try store.reset()
        } catch {
            reportFailure("Reset virtual display configs", error)
            do {
                try store.save([])
            } catch {
                reportFailure("Reset fallback save empty configs", error)
            }
        }
    }

    func restoreDesiredVirtualDisplays(
        from configs: [VirtualDisplayConfig],
        restorer: (VirtualDisplayConfig) throws -> Void
    ) -> [VirtualDisplayRestoreFailure] {
        var failures: [VirtualDisplayRestoreFailure] = []
        for config in configs where config.desiredEnabled {
            do {
                try restorer(config)
            } catch {
                let message = error.localizedDescription
                AppLog.persistence.error(
                    "Restore virtual display failed (serial: \(config.serialNum, privacy: .public), name: \(config.name, privacy: .public)): \(message, privacy: .public)"
                )
                failures.append(
                    .init(
                        id: config.id,
                        name: config.name,
                        serialNum: config.serialNum,
                        message: message
                    )
                )
            }
        }
        return failures
    }
}
