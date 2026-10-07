import CoreGraphics
import Foundation
import VoidDisplayRuntime
enum DisplaySurfaceStatusPresentation {
static func runtimeConsumerKinds(
        aggregate: DisplayRuntimeAggregatedDemand?,
        effectiveIntent: DisplayRuntimeEffectiveCaptureIntent?
    ) -> Set<DisplaySurfaceConsumerKind> {
        let aggregateKinds = aggregate?.consumerKinds ?? []
        let intentKinds = effectiveIntent?.intent.aggregateDemand?.consumerKinds ?? []
        return Set(aggregateKinds + intentKinds)
    }

    static func hasRuntimeDemand(
        kind: DisplaySurfaceConsumerKind,
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        runtimeConsumerKinds: Set<DisplaySurfaceConsumerKind>
    ) -> Bool {
        leases.contains { $0.state.contributesDemand } || runtimeConsumerKinds.contains(kind)
    }

static func virtualDisplayStatus(
        for surface: DisplaySurface,
        snapshot: DisplayRuntimeSnapshot
    ) -> (value: String, tone: DisplaySurfaceStatusTone)? {
        guard let state = surface.managedVirtualDisplay else {
            return nil
        }
        let configurationStatus: String
        switch state.desiredEnabled {
        case true:
            configurationStatus = String(localized: "Enabled")
        case false:
            return (String(localized: "Disabled"), .neutral)
        case nil:
            return (String(localized: "Configuration Missing"), .danger)
        }

        let runtimeStatus = virtualDisplayRuntimeStatus(
            surface: surface,
            state: state,
            snapshot: snapshot
        )
        return (
            "\(configurationStatus) · \(runtimeStatus.value)",
            runtimeStatus.tone
        )
    }

    static func virtualDisplayRuntimeStatus(
        surface: DisplaySurface,
        state: DisplayRuntimeManagedVirtualDisplaySurfaceState,
        snapshot: DisplayRuntimeSnapshot
    ) -> (value: String, tone: DisplaySurfaceStatusTone) {
        if hasActiveVirtualDisplayAttempt(configID: state.configID, snapshot: snapshot) {
            return (String(localized: "Starting"), .warning)
        }
        if surface.currentDisplayID != nil && (state.isRunning || state.isLiveRuntime) {
            return (String(localized: "Running"), .success)
        }
        if virtualDisplayFailureReason(state: state, snapshot: snapshot) != nil {
            return (String(localized: "Startup Failed"), .danger)
        }
        return (String(localized: "Not Running"), .warning)
    }

    static func virtualDisplayFailureReason(
        state: DisplayRuntimeManagedVirtualDisplaySurfaceState,
        snapshot: DisplayRuntimeSnapshot
    ) -> String? {
        if state.isRunning || state.isLiveRuntime {
            return nil
        }
        if let trace = latestVirtualDisplayLifecycleTrace(configID: state.configID, snapshot: snapshot) {
            guard trace.status == .failed else { return nil }
            return trace.failure?.reason
                ?? trace.startupRestoreCommandResult?.failureReason
                ?? "virtual_display_transaction_failed"
        }
        return state.hasRestoreFailure ? "virtual_display_restore_failed" : nil
    }

    static func hasActiveVirtualDisplayAttempt(
        configID: UUID,
        snapshot: DisplayRuntimeSnapshot
    ) -> Bool {
        snapshot.transactions.activeTransactions.contains { trace in
            guard trace.status == .active else { return false }
            switch trace.kind {
            case .virtualDisplayStartupRestore:
                return trace.startupRestoreIntent?.configID == configID
                    || trace.startupRestoreCommandResult?.configID == configID
                    || trace.affectedSurfaces.contains { $0.identity == .managedVirtualDisplay(configID: configID) }
            case .virtualDisplayRebuild, .virtualDisplayEnable:
                return trace.targetConfigID == configID
                    || trace.affectedSurfaces.contains { $0.identity == .managedVirtualDisplay(configID: configID) }
            case .virtualDisplayEditRebuild:
                return trace.targetConfigID == configID
                    || trace.affectedSurfaces.contains { $0.identity == .managedVirtualDisplay(configID: configID) }
            case .virtualDisplayDisable, .virtualDisplayCreate, .virtualDisplayDelete:
                return false
            }
        }
    }

    static func latestVirtualDisplayLifecycleTrace(
        configID: UUID,
        snapshot: DisplayRuntimeSnapshot
    ) -> DisplayRuntimeTransactionTrace? {
        snapshot.transactions.recentTransactions.first { trace in
            switch trace.kind {
            case .virtualDisplayStartupRestore:
                return trace.startupRestoreCommandResult?.configID == configID
                    || trace.startupRestoreIntent?.configID == configID
                    || trace.affectedSurfaces.contains {
                        $0.identity == .managedVirtualDisplay(configID: configID)
                    }
            case .virtualDisplayRebuild, .virtualDisplayEnable, .virtualDisplayEditRebuild:
                return trace.targetConfigID == configID
                    || trace.affectedSurfaces.contains {
                        $0.identity == .managedVirtualDisplay(configID: configID)
                    }
            case .virtualDisplayDisable, .virtualDisplayCreate, .virtualDisplayDelete:
                return false
            }
        }
    }

    static func previewStatus(
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        hasRuntimeDemand: Bool
    ) -> (value: String, tone: DisplaySurfaceStatusTone) {
        if leases.contains(where: { $0.state == .failed }) {
            return (String(localized: "Failed"), .danger)
        }
        if leases.contains(where: { $0.state == .restarting }) {
            return (String(localized: "Restarting"), .warning)
        }
        if leases.contains(where: { $0.state == .draining }) {
            return (String(localized: "Draining"), .warning)
        }
        if hasRuntimeDemand {
            return (String(localized: "Previewing"), .success)
        }
        return (String(localized: "Off"), .neutral)
    }

    static func lanWebViewStatus(
        surface: DisplaySurface,
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        hasRuntimeDemand: Bool
    ) -> (value: String, tone: DisplaySurfaceStatusTone) {
        if leases.contains(where: { $0.state == .failed }) {
            return (String(localized: "Failed"), .danger)
        }
        if leases.contains(where: { $0.state == .restarting }) {
            return (String(localized: "Restarting"), .warning)
        }
        if leases.contains(where: { $0.state == .draining }) {
            return (String(localized: "Draining"), .warning)
        }
        if hasRuntimeDemand {
            return (String(localized: "Sharing"), .success)
        }
        return (String(localized: "Off"), .neutral)
    }

    static func issueStatus(for lastFailureCode: String?) -> (value: String, tone: DisplaySurfaceStatusTone)? {
        guard let lastFailureCode else {
            return nil
        }
        if lastFailureCode.hasPrefix("startup_restore_") || lastFailureCode.hasPrefix("virtual_display_") {
            return (String(localized: "Startup Failed"), .danger)
        }
        return (String(localized: "Failed"), .danger)
    }

static func captureStateStatus(
        _ effectiveIntent: DisplayRuntimeEffectiveCaptureIntent?
    ) -> String {
        guard let effectiveIntent else {
            return String(localized: "No active capture")
        }
        let kind: String
        switch effectiveIntent.intent.kind {
        case .capture:
            kind = String(localized: "Capture")
        case .drain:
            kind = String(localized: "Drain")
        }
        let reason = reasonText(effectiveIntent.intent.reason)
        let outcome = effectiveIntent.lastApplyResult.map {
            outcomeText($0.outcome)
        } ?? String(localized: "Pending")
        return [kind, reason, outcome].joined(separator: ", ")
    }

    static func runtimeAttachmentStatus(_ leases: [DisplayRuntimeConsumerLeaseSnapshot]) -> String {
        guard leases.isEmpty == false else {
            return String(localized: "No attachments")
        }
        let activeCount = leases.filter { $0.state.contributesDemand }.count
        return String(
            format: String(localized: "%lld of %lld active"),
            Int64(activeCount),
            Int64(leases.count)
        )
    }

    static func lastFailureCode(
        surface: DisplaySurface,
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        effectiveIntent: DisplayRuntimeEffectiveCaptureIntent?,
        sharing: DisplayRuntimeSharingSnapshot,
        snapshot: DisplayRuntimeSnapshot
    ) -> String? {
        if let code = leases.compactMap(\.lastFailureCode).first {
            return code
        }
        if let code = effectiveIntent?.lastFailureCode ?? effectiveIntent?.intent.lastFailureCode {
            return code
        }
        if let code = effectiveIntent?.lastApplyResult?.failureCode {
            return code
        }
        if let state = surface.managedVirtualDisplay,
           !hasActiveVirtualDisplayAttempt(configID: state.configID, snapshot: snapshot),
           let reason = virtualDisplayFailureReason(state: state, snapshot: snapshot) {
            return reason
        }
        if sharing.lifecycle.phase == .failed,
           surface.sharing != nil,
           let reason = sharing.lifecycle.failureReason {
            return reason
        }
        return nil
    }

    static func reasonText(_ reason: DisplayRuntimeCaptureIntentReason) -> String {
        switch reason {
        case .attach:
            String(localized: "Attach")
        case .detach:
            String(localized: "Detach")
        case .epochChanged:
            String(localized: "Epoch changed")
        case .transactionQuiesce:
            String(localized: "Transaction quiesce")
        case .performanceModeChanged:
            String(localized: "Performance mode changed")
        case .retry:
            String(localized: "Retry")
        }
    }

    static func outcomeText(_ outcome: DisplayRuntimeCaptureIntentApplyOutcome) -> String {
        switch outcome {
        case .applied:
            String(localized: "Applied")
        case .failed:
            String(localized: "Failed")
        case .ignored:
            String(localized: "Ignored")
        }
    }
}
