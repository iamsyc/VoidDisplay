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
    private let store: any VirtualDisplayStoring

    init(store: any VirtualDisplayStoring) {
        self.store = store
    }

    convenience init() {
        self.init(store: VirtualDisplayStore())
    }

    func loadConfigs() -> [VirtualDisplayConfig] {
        do {
            return try store.load()
        } catch {
            AppErrorMapper.logFailure("Load virtual display configs", error: error, logger: AppLog.persistence)
            return []
        }
    }

    func saveConfigs(_ configs: [VirtualDisplayConfig]) {
        do {
            try store.save(configs)
        } catch {
            AppErrorMapper.logFailure("Save virtual display configs", error: error, logger: AppLog.persistence)
        }
    }

    func resetConfigs() {
        do {
            try store.reset()
        } catch {
            AppErrorMapper.logFailure("Reset virtual display configs", error: error, logger: AppLog.persistence)
            do {
                try store.save([])
            } catch {
                AppErrorMapper.logFailure("Reset fallback save empty configs", error: error, logger: AppLog.persistence)
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
