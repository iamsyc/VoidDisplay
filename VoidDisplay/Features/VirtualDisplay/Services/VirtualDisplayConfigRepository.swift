import Foundation
import OSLog

protocol VirtualDisplayStoring {
    func load() throws -> [VirtualDisplayConfig]
    func save(_ configs: [VirtualDisplayConfig]) throws
    func reset() throws
    func diagnostics() throws -> VirtualDisplayStoreDiagnostics
}

extension VirtualDisplayStore: VirtualDisplayStoring {}

enum VirtualDisplayConfigRepositoryState {
    case ready(diagnostics: VirtualDisplayStoreDiagnostics)
    case loadFailed(error: VirtualDisplayConfigStoreError, diagnostics: VirtualDisplayStoreDiagnostics)
}

@MainActor
final class VirtualDisplayConfigRepository {
    typealias FailureReporter = (_ operation: String, _ error: Error) -> Void

    enum PersistReason: String {
        case userCreatedConfig
        case userEditedConfig
        case userReorderedConfigs
        case userDeletedConfig
        case userToggledDesiredEnabled
        case restoreDesiredStateSync
        case runtimeDisableCleanup
        case runtimeRebuildRecovery
    }

    enum LoadResult {
        case success([VirtualDisplayConfig])
        case failure(VirtualDisplayConfigStoreError)
    }

    private let store: any VirtualDisplayStoring
    private let reportFailure: FailureReporter
    private var lastPersistedDisplayNamesByConfigId: [UUID: String] = [:]

    private(set) var state: VirtualDisplayConfigRepositoryState

    init(
        store: (any VirtualDisplayStoring)? = nil,
        reportFailure: FailureReporter? = nil
    ) {
        let resolvedStore = store ?? VirtualDisplayStore()
        self.store = resolvedStore
        self.reportFailure = reportFailure ?? { operation, error in
            AppErrorMapper.logFailure(operation, error: error, logger: AppLog.persistence)
        }
        self.state = .ready(diagnostics: Self.resolveDiagnostics(from: resolvedStore))
    }

    var loadFailureMessage: String? {
        guard case .loadFailed(let error, _) = state else { return nil }
        return error.userFacingMessage
    }

    var diagnosticsSummary: String {
        diagnostics.summary
    }

    var diagnostics: VirtualDisplayStoreDiagnostics {
        switch state {
        case .ready(let diagnostics):
            return diagnostics
        case .loadFailed(_, let diagnostics):
            return diagnostics
        }
    }

    func load() -> LoadResult {
        let diagnostics = Self.resolveDiagnostics(from: store)
        do {
            let configs = try store.load()
            lastPersistedDisplayNamesByConfigId = Dictionary(
                uniqueKeysWithValues: configs.map { ($0.id, $0.displayName) }
            )
            state = .ready(diagnostics: diagnostics)
            return .success(configs)
        } catch let error as VirtualDisplayConfigStoreError {
            reportFailure("Load virtual display configs", error)
            lastPersistedDisplayNamesByConfigId.removeAll()
            state = .loadFailed(error: error, diagnostics: diagnostics)
            return .failure(error)
        } catch {
            reportFailure("Load virtual display configs", error)
            let wrapped = VirtualDisplayConfigStoreError.ioFailed(operation: "load", underlying: error)
            lastPersistedDisplayNamesByConfigId.removeAll()
            state = .loadFailed(error: wrapped, diagnostics: diagnostics)
            return .failure(wrapped)
        }
    }

    @discardableResult
    func save(_ configs: [VirtualDisplayConfig], reason: PersistReason) -> Bool {
        guard isWritable(for: reason) else { return false }
        guard validateDisplayNameMutation(in: configs, for: reason) else { return false }
        do {
            try store.save(configs)
        } catch {
            reportFailure("Save virtual display configs", error)
            return false
        }
        lastPersistedDisplayNamesByConfigId = Dictionary(
            uniqueKeysWithValues: configs.map { ($0.id, $0.displayName) }
        )
        state = .ready(diagnostics: Self.resolveDiagnostics(from: store))
        return true
    }

    @discardableResult
    func reset() -> Bool {
        do {
            try store.reset()
            lastPersistedDisplayNamesByConfigId.removeAll()
            state = .ready(diagnostics: Self.resolveDiagnostics(from: store))
            return true
        } catch {
            reportFailure("Reset virtual display configs", error)
            return false
        }
    }

    private func isWritable(for reason: PersistReason) -> Bool {
        guard case .loadFailed(let error, let diagnostics) = state else { return true }
        AppLog.virtualDisplay.error(
            "Blocked virtual display config persistence due to config store load failure (reason: \(reason.rawValue, privacy: .public), \(diagnostics.summary, privacy: .public)): \(String(describing: error), privacy: .public)"
        )
        return false
    }

    private func validateDisplayNameMutation(in configs: [VirtualDisplayConfig], for reason: PersistReason) -> Bool {
        guard !reasonAllowsDisplayNameMutation(reason) else { return true }
        for config in configs {
            guard let previousName = lastPersistedDisplayNamesByConfigId[config.id] else { continue }
            guard previousName != config.displayName else { continue }
            AppLog.virtualDisplay.error(
                "Blocked disallowed displayName mutation (reason: \(reason.rawValue, privacy: .public), config: \(config.id.uuidString, privacy: .public), previous: \(previousName, privacy: .public), current: \(config.displayName, privacy: .public))."
            )
            return false
        }
        return true
    }

    private func reasonAllowsDisplayNameMutation(_ reason: PersistReason) -> Bool {
        switch reason {
        case .userCreatedConfig, .userEditedConfig:
            true
        case .userReorderedConfigs, .userDeletedConfig, .userToggledDesiredEnabled,
                .restoreDesiredStateSync, .runtimeDisableCleanup, .runtimeRebuildRecovery:
            false
        }
    }

    private static func resolveDiagnostics(from store: any VirtualDisplayStoring) -> VirtualDisplayStoreDiagnostics {
        (try? store.diagnostics()) ?? fallbackDiagnostics()
    }

    private static func fallbackDiagnostics() -> VirtualDisplayStoreDiagnostics {
        VirtualDisplayStoreDiagnostics(
            primaryStoreURL: URL(fileURLWithPath: "/unavailable"),
            isTestIsolatedPath: false
        )
    }
}
