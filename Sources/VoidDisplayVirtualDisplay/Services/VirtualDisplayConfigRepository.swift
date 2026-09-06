import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import OSLog
package protocol VirtualDisplayStoring {
    func load() throws -> [VirtualDisplayConfig]
    func save(_ configs: [VirtualDisplayConfig]) throws
    func reset() throws
    func diagnostics() -> VirtualDisplayStoreDiagnostics
}

extension VirtualDisplayStore: VirtualDisplayStoring {}
package enum VirtualDisplayConfigRepositoryState {
    case ready(diagnostics: VirtualDisplayStoreDiagnostics)
    case loadFailed(error: VirtualDisplayConfigStoreError, diagnostics: VirtualDisplayStoreDiagnostics)
}

@MainActor
package final class VirtualDisplayConfigRepository {
    package typealias FailureReporter = (_ operation: String, _ error: Error) -> Void
    package enum LoadResult {
        case success([VirtualDisplayConfig])
        case failure(VirtualDisplayConfigStoreError)
    }

    private let store: any VirtualDisplayStoring
    private let reportFailure: FailureReporter

    private(set) var state: VirtualDisplayConfigRepositoryState

    package init(
        store: any VirtualDisplayStoring,
        reportFailure: FailureReporter? = nil
    ) {
        self.store = store
        self.reportFailure = reportFailure ?? { operation, error in
            AppErrorMapper.logFailure(operation, error: error, logger: AppLog.persistence)
        }
        self.state = .ready(diagnostics: store.diagnostics())
    }

    package var loadFailureMessage: String? {
        guard case .loadFailed(let error, _) = state else { return nil }
        return error.userFacingMessage
    }

    package var diagnosticsSummary: String {
        diagnostics.summary
    }

    package var diagnostics: VirtualDisplayStoreDiagnostics {
        switch state {
        case .ready(let diagnostics):
            return diagnostics
        case .loadFailed(_, let diagnostics):
            return diagnostics
        }
    }

    package func load() -> LoadResult {
        let diagnostics = store.diagnostics()
        do {
            let configs = try store.load()
            state = .ready(diagnostics: diagnostics)
            return .success(configs)
        } catch {
            reportFailure("Load virtual display configs", error)
            let wrapped = error as? VirtualDisplayConfigStoreError
                ?? .ioFailed(operation: "load", underlying: error)
            state = .loadFailed(error: wrapped, diagnostics: diagnostics)
            return .failure(wrapped)
        }
    }

    package func save(_ configs: [VirtualDisplayConfig]) throws {
        try ensureWritable()
        do {
            try store.save(configs)
        } catch {
            reportFailure("Save virtual display configs", error)
            throw error
        }
        state = .ready(diagnostics: store.diagnostics())
    }

    package func reset() throws {
        do {
            try store.reset()
            state = .ready(diagnostics: store.diagnostics())
        } catch {
            reportFailure("Reset virtual display configs", error)
            throw error
        }
    }

    private func ensureWritable() throws {
        guard case .loadFailed(let error, let diagnostics) = state else { return }
        AppLog.virtualDisplay.error(
            "Blocked virtual display config persistence due to config store load failure (\(diagnostics.summary, privacy: .public)): \(String(describing: error), privacy: .public)"
        )
        throw error
    }
}
