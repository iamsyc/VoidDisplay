import VoidDisplayObservability
import VoidDisplayRuntime
import Foundation

package nonisolated enum RuntimeDiagnosticsAvailability: Equatable, Sendable {
    case available
    case unavailable(RuntimeDiagnosticsUnavailableReason)
    case degraded(RuntimeDiagnosticsUnavailableReason)
}

package nonisolated enum RuntimeDiagnosticsUnavailableReason: String, Equatable, Sendable {
    case snapshotUnavailable = "snapshot_unavailable"
    case runtimeSectionMissing = "runtime_section_missing"
    case runtimeSectionDecodeFailed = "runtime_section_decode_failed"
}

package nonisolated struct RuntimeDiagnosticsSummary: Equatable, Sendable {
    package let availability: RuntimeDiagnosticsAvailability
    package let schemaVersion: Int?
    package let surfaceCount: Int
    package let virtualDisplayCount: Int
    package let runningVirtualDisplayCount: Int
    package let physicalDisplayCount: Int
    package let totalConsumerLeaseCount: Int
    package let activeConsumerLeaseCount: Int
    package let aggregatedDemandCount: Int
    package let activeViewerCount: Int
    package let effectiveCaptureIntentCount: Int
    package let activeTransactionCount: Int
    package let recentTransactionCount: Int
    package let recentFailureCount: Int
    package let lastFailureCode: String?

    package init(state: ObservabilityStateSnapshot?) {
        guard let state else {
            self = .unavailable(.snapshotUnavailable)
            return
        }
        guard let section = state.sections["runtime"] else {
            self = .unavailable(.runtimeSectionMissing)
            return
        }
        guard let runtime = try? section.decode(DisplayRuntimeSnapshot.self) else {
            self = .degraded(.runtimeSectionDecodeFailed)
            return
        }
        self.init(runtime: runtime)
    }

    package var statusCode: String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable:\(reason.rawValue)"
        case .degraded(let reason):
            return "degraded:\(reason.rawValue)"
        }
    }

    package var isAvailable: Bool {
        availability == .available
    }

    private init(runtime: DisplayRuntimeSnapshot) {
        availability = .available
        schemaVersion = runtime.schemaVersion
        surfaceCount = runtime.surfaces.count
        virtualDisplayCount = runtime.surfaces.count { $0.kind == .managedVirtualDisplay }
        runningVirtualDisplayCount = runtime.surfaces.count {
            guard let managed = $0.managedVirtualDisplay else { return false }
            return $0.currentDisplayID != nil && (managed.isRunning || managed.isLiveRuntime)
        }
        physicalDisplayCount = runtime.surfaces.count { $0.kind == .physicalDisplay }
        totalConsumerLeaseCount = runtime.consumerSummary.totalLeaseCount
        activeConsumerLeaseCount = runtime.consumerSummary.activeLeaseCount
        aggregatedDemandCount = runtime.aggregatedDemands.count
        activeViewerCount = runtime.consumerSummary.activeViewerCount
        effectiveCaptureIntentCount = runtime.effectiveCaptureIntents.count
        activeTransactionCount = runtime.transactions.activeTransactions.count
        recentTransactionCount = runtime.transactions.recentTransactions.count
        recentFailureCount = Self.recentFailureCount(from: runtime)
        lastFailureCode = Self.latestFailureCode(from: runtime)
    }

    private static func unavailable(_ reason: RuntimeDiagnosticsUnavailableReason) -> Self {
        Self(availability: .unavailable(reason))
    }

    private static func degraded(_ reason: RuntimeDiagnosticsUnavailableReason) -> Self {
        Self(availability: .degraded(reason))
    }

    private init(availability: RuntimeDiagnosticsAvailability) {
        self.availability = availability
        schemaVersion = nil
        surfaceCount = 0
        virtualDisplayCount = 0
        runningVirtualDisplayCount = 0
        physicalDisplayCount = 0
        totalConsumerLeaseCount = 0
        activeConsumerLeaseCount = 0
        aggregatedDemandCount = 0
        activeViewerCount = 0
        effectiveCaptureIntentCount = 0
        activeTransactionCount = 0
        recentTransactionCount = 0
        recentFailureCount = 0
        lastFailureCode = nil
    }

    private static func recentFailureCount(from runtime: DisplayRuntimeSnapshot) -> Int {
        let transactionFailures = runtime.transactions.recentTransactions.count {
            $0.failure != nil || $0.compensation.failureReason != nil
        }
        let intentFailures = runtime.effectiveCaptureIntents.count {
            $0.lastFailureCode != nil || $0.lastApplyResult?.failureCode != nil || $0.intent.lastFailureCode != nil
        }
        let leaseFailures = runtime.consumerLeases.count { $0.lastFailureCode != nil }
        return transactionFailures + intentFailures + leaseFailures
    }

    private static func latestFailureCode(from runtime: DisplayRuntimeSnapshot) -> String? {
        let transactionsByRecency =
            runtime.transactions.recentTransactions +
            Array(runtime.transactions.activeTransactions.reversed())
        for transaction in transactionsByRecency {
            if let reason = transaction.failure?.reason {
                return reason
            }
            if let reason = transaction.compensation.failureReason {
                return reason
            }
        }

        for intent in runtime.effectiveCaptureIntents.reversed() {
            if let code = intent.lastFailureCode ?? intent.lastApplyResult?.failureCode ?? intent.intent.lastFailureCode {
                return code
            }
        }

        return runtime.consumerLeases.reversed().compactMap(\.lastFailureCode).first
    }
}
