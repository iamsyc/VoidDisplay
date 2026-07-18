import CoreGraphics
import Foundation
import VoidDisplayRuntime

package struct DisplaySurfaceListPresentation: Equatable {
    package let surfaces: [DisplaySurfacePresentation]

    package init(surfaces: [DisplaySurfacePresentation]) {
        self.surfaces = surfaces
    }
}

package struct DisplaySurfacePresentation: Identifiable, Equatable {
    package let id: String
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let displayID: CGDirectDisplayID?
    package let title: String
    package let subtitle: String
    package let isManagedVirtualDisplay: Bool
    package let isPreviewing: Bool
    package let isSharing: Bool
    package let rowActions: [DisplaySurfaceRowActionPresentation]
    package let compactStatusItems: [DisplaySurfaceStatusItemPresentation]
    package let technicalStatusItems: [DisplaySurfaceStatusItemPresentation]
    package let accessibilitySummary: String

    package init(
        id: String,
        surfaceIdentity: DisplaySurfaceIdentity,
        displayID: CGDirectDisplayID?,
        title: String,
        subtitle: String,
        isManagedVirtualDisplay: Bool,
        isPreviewing: Bool,
        isSharing: Bool,
        rowActions: [DisplaySurfaceRowActionPresentation],
        compactStatusItems: [DisplaySurfaceStatusItemPresentation],
        technicalStatusItems: [DisplaySurfaceStatusItemPresentation],
        accessibilitySummary: String
    ) {
        self.id = id
        self.surfaceIdentity = surfaceIdentity
        self.displayID = displayID
        self.title = title
        self.subtitle = subtitle
        self.isManagedVirtualDisplay = isManagedVirtualDisplay
        self.isPreviewing = isPreviewing
        self.isSharing = isSharing
        self.rowActions = rowActions
        self.compactStatusItems = compactStatusItems
        self.technicalStatusItems = technicalStatusItems
        self.accessibilitySummary = accessibilitySummary
    }
}

package enum DisplaySurfaceRowActionKind: String, Equatable {
    case openPreview
    case stopPreview
    case openLANWebView
    case stopLANWebView
}

package struct DisplaySurfaceRowActionPresentation: Identifiable, Equatable {
    package let kind: DisplaySurfaceRowActionKind
    package let title: String
    package let help: String
    package let systemImage: String
    package let accessibilityIdentifier: String
    package let isEnabled: Bool
    package let isDestructive: Bool

    package var id: String {
        kind.rawValue
    }

    package init(
        kind: DisplaySurfaceRowActionKind,
        title: String,
        help: String? = nil,
        systemImage: String,
        accessibilityIdentifier: String,
        isEnabled: Bool,
        isDestructive: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.help = help ?? title
        self.systemImage = systemImage
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
    }
}

package struct DisplaySurfaceStatusItemPresentation: Identifiable, Equatable {
    package let id: String
    package let title: String
    package let value: String
    package let accessibilityIdentifier: String
    package let tone: DisplaySurfaceStatusTone
    package let isFailureCode: Bool

    package init(
        id: String,
        title: String,
        value: String,
        accessibilityIdentifier: String,
        tone: DisplaySurfaceStatusTone = .neutral,
        isFailureCode: Bool = false
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.accessibilityIdentifier = accessibilityIdentifier
        self.tone = tone
        self.isFailureCode = isFailureCode
    }
}

package enum DisplaySurfaceStatusTone: Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
}

package enum DisplaySurfacePresentationMapper {
    package static func makePresentation(
        snapshot: DisplayRuntimeSnapshot,
        virtualDisplayNamesByConfigID: [UUID: String] = [:]
    ) -> DisplaySurfaceListPresentation {
        let displayableSurfaces = snapshot.surfaces.filter {
            shouldPresent($0, snapshot: snapshot)
        }
        let virtualDisplayCount = displayableSurfaces.count { $0.kind == .managedVirtualDisplay }
        let physicalDisplayCount = displayableSurfaces.count { $0.kind == .physicalDisplay }
        var virtualDisplayIndex = 0
        var physicalDisplayIndex = 0
        let surfaces = displayableSurfaces.map { surface in
            let ordinal: Int?
            switch surface.kind {
            case .managedVirtualDisplay:
                virtualDisplayIndex += 1
                ordinal = virtualDisplayCount > 1 ? virtualDisplayIndex : nil
            case .physicalDisplay:
                physicalDisplayIndex += 1
                ordinal = physicalDisplayCount > 1 ? physicalDisplayIndex : nil
            }
            return makeSurfacePresentation(
                surface: surface,
                snapshot: snapshot,
                ordinal: ordinal,
                virtualDisplayNamesByConfigID: virtualDisplayNamesByConfigID
            )
        }
        return DisplaySurfaceListPresentation(surfaces: surfaces)
    }

    private static func shouldPresent(
        _ surface: DisplaySurface,
        snapshot: DisplayRuntimeSnapshot
    ) -> Bool {
        switch surface.kind {
        case .managedVirtualDisplay:
            return true
        case .physicalDisplay:
            return hasPhysicalDisplayUserActivity(surface, snapshot: snapshot)
        }
    }

    private static func hasPhysicalDisplayUserActivity(
        _ surface: DisplaySurface,
        snapshot: DisplayRuntimeSnapshot
    ) -> Bool {
        if snapshot.consumerLeases.contains(where: { $0.surfaceIdentity == surface.identity }) {
            return true
        }
        if snapshot.aggregatedDemands.contains(where: { $0.surfaceIdentity == surface.identity }) {
            return true
        }
        if snapshot.effectiveCaptureIntents.contains(where: { $0.intent.surfaceIdentity == surface.identity }) {
            return true
        }
        if let capture = surface.capture,
           capture.isStarting || !capture.sessionIDs.isEmpty || capture.receivedFrameCount > 0 {
            return true
        }
        if let sharing = surface.sharing,
           sharing.isStarting || sharing.isActive || sharing.viewerCount > 0 {
            return true
        }
        return false
    }

    private static func makeSurfacePresentation(
        surface: DisplaySurface,
        snapshot: DisplayRuntimeSnapshot,
        ordinal: Int?,
        virtualDisplayNamesByConfigID: [UUID: String]
    ) -> DisplaySurfacePresentation {
        let leases = snapshot.consumerLeases.filter { $0.surfaceIdentity == surface.identity }
        let aggregate = snapshot.aggregatedDemands.first { $0.surfaceIdentity == surface.identity }
        let effectiveIntent = snapshot.effectiveCaptureIntents.last { $0.intent.surfaceIdentity == surface.identity }
        let previewLeases = leases.filter { $0.kind == .preview }
        let lanWebViewLeases = leases.filter { $0.kind == .lanWebView }
        let runtimeConsumerKinds = runtimeConsumerKinds(
            aggregate: aggregate,
            effectiveIntent: effectiveIntent
        )
        let lastFailureCode = lastFailureCode(
            surface: surface,
            leases: leases,
            effectiveIntent: effectiveIntent,
            sharing: snapshot.sharing,
            snapshot: snapshot
        )
        let isPreviewing = hasRuntimeDemand(
            kind: .preview,
            leases: previewLeases,
            runtimeConsumerKinds: runtimeConsumerKinds
        )
        let isSharing = hasRuntimeDemand(
            kind: .lanWebView,
            leases: lanWebViewLeases,
            runtimeConsumerKinds: runtimeConsumerKinds
        )
        let viewerCount = max(surface.sharing?.viewerCount ?? 0, aggregate?.activeViewerCount ?? 0)
        let title = title(
            for: surface,
            ordinal: ordinal,
            virtualDisplayNamesByConfigID: virtualDisplayNamesByConfigID
        )
        let subtitle = subtitle(for: surface)
        let virtualDisplayStatus = virtualDisplayStatus(
            for: surface,
            snapshot: snapshot
        )
        let previewStatus = previewStatus(
            leases: previewLeases,
            hasRuntimeDemand: isPreviewing
        )
        let lanWebViewStatus = lanWebViewStatus(
            surface: surface,
            leases: lanWebViewLeases,
            hasRuntimeDemand: isSharing
        )
        var compactStatusItems: [DisplaySurfaceStatusItemPresentation] = []
        if let virtualDisplayStatus {
            compactStatusItems.append(
                DisplaySurfaceStatusItemPresentation(
                    id: "virtualDisplay",
                    title: String(localized: "Virtual Display"),
                    value: virtualDisplayStatus.value,
                    accessibilityIdentifier: "displays_virtual_display_status",
                    tone: virtualDisplayStatus.tone
                )
            )
        }
        compactStatusItems.append(contentsOf: [
            DisplaySurfaceStatusItemPresentation(
                id: "preview",
                title: String(localized: "Preview"),
                value: previewStatus.value,
                accessibilityIdentifier: "displays_preview_status",
                tone: previewStatus.tone
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "webView",
                title: String(localized: "Web Sharing"),
                value: lanWebViewStatus.value,
                accessibilityIdentifier: "displays_lan_web_view_status",
                tone: lanWebViewStatus.tone
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "viewerCount",
                title: String(localized: "Viewers"),
                value: String(viewerCount),
                accessibilityIdentifier: "displays_viewer_count",
                tone: viewerCount > 0 ? .info : .neutral
            )
        ])
        if let issueStatus = issueStatus(for: lastFailureCode) {
            compactStatusItems.append(DisplaySurfaceStatusItemPresentation(
                id: "issue",
                title: String(localized: "Last Failure"),
                value: issueStatus.value,
                accessibilityIdentifier: "displays_issue_status",
                tone: issueStatus.tone
            ))
        }
        let canStopPreview = surface.currentDisplayID != nil
            && previewLeases.contains { $0.state.contributesDemand }
        let canStopLANWebViewSharing = surface.currentDisplayID != nil
            && lanWebViewLeases.contains { $0.state.contributesDemand }
        let rowActions = rowActions(
            isPreviewing: isPreviewing,
            isSharing: isSharing,
            canStopPreview: canStopPreview,
            canStopLANWebViewSharing: canStopLANWebViewSharing
        )
        let accessibilitySummary = accessibilitySummary(
            title: title,
            statusItems: compactStatusItems
        )
        let technicalStatusItems = [
            DisplaySurfaceStatusItemPresentation(
                id: "identity",
                title: String(localized: "Display Identifier"),
                value: redactedIdentityText(for: surface.identity),
                accessibilityIdentifier: "displays_surface_identity_value"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "captureState",
                title: String(localized: "Capture State"),
                value: captureStateStatus(effectiveIntent),
                accessibilityIdentifier: "displays_capture_state_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "lease",
                title: String(localized: "Runtime Attachment"),
                value: runtimeAttachmentStatus(leases),
                accessibilityIdentifier: "displays_lease_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "lastFailureCode",
                title: String(localized: "Diagnostic Code"),
                value: lastFailureCode ?? String(localized: "None"),
                accessibilityIdentifier: "displays_last_failure_code",
                isFailureCode: lastFailureCode != nil
            )
        ]

        return DisplaySurfacePresentation(
            id: "\(surface.identity.kind.rawValue):\(surface.identity.stableID)",
            surfaceIdentity: surface.identity,
            displayID: surface.currentDisplayID,
            title: title,
            subtitle: subtitle,
            isManagedVirtualDisplay: surface.kind == .managedVirtualDisplay,
            isPreviewing: isPreviewing,
            isSharing: isSharing,
            rowActions: rowActions,
            compactStatusItems: compactStatusItems,
            technicalStatusItems: technicalStatusItems,
            accessibilitySummary: accessibilitySummary
        )
    }

    private static func runtimeConsumerKinds(
        aggregate: DisplayRuntimeAggregatedDemand?,
        effectiveIntent: DisplayRuntimeEffectiveCaptureIntent?
    ) -> Set<DisplaySurfaceConsumerKind> {
        let aggregateKinds = aggregate?.consumerKinds ?? []
        let intentKinds = effectiveIntent?.intent.aggregateDemand?.consumerKinds ?? []
        return Set(aggregateKinds + intentKinds)
    }

    private static func hasRuntimeDemand(
        kind: DisplaySurfaceConsumerKind,
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        runtimeConsumerKinds: Set<DisplaySurfaceConsumerKind>
    ) -> Bool {
        leases.contains { $0.state.contributesDemand } || runtimeConsumerKinds.contains(kind)
    }

    private static func title(
        for surface: DisplaySurface,
        ordinal: Int?,
        virtualDisplayNamesByConfigID: [UUID: String]
    ) -> String {
        switch surface.kind {
        case .managedVirtualDisplay:
            if let configID = surface.managedVirtualDisplay?.configID,
               let displayName = virtualDisplayNamesByConfigID[configID]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !displayName.isEmpty {
                return displayName
            }
            if let ordinal {
                return String(format: String(localized: "Virtual Display %lld"), Int64(ordinal))
            } else {
                return String(localized: "Virtual Display")
            }
        case .physicalDisplay:
            if let ordinal {
                return String(format: String(localized: "Physical Display %lld"), Int64(ordinal))
            } else {
                return String(localized: "Physical Display")
            }
        }
    }

    private static func subtitle(for surface: DisplaySurface) -> String {
        pixelResolutionText(for: surface) ?? String(localized: "Resolution unavailable")
    }

    private static func redactedIdentityText(for identity: DisplaySurfaceIdentity) -> String {
        let digest = redactedDigest(for: "\(identity.kind.rawValue):\(identity.stableID)")
        return String(format: String(localized: "ID hash %@"), digest)
    }

    private static func redactedDigest(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%06llx", hash & 0xFF_FFFF)
    }

    private static func pixelResolutionText(for surface: DisplaySurface) -> String? {
        if let catalog = surface.catalog,
           let width = catalog.pixelWidth,
           let height = catalog.pixelHeight {
            return String(format: String(localized: "%lld × %lld pixels"), Int64(width), Int64(height))
        }
        if let managed = surface.managedVirtualDisplay,
           let width = managed.maximumPixelWidth,
           let height = managed.maximumPixelHeight {
            return String(format: String(localized: "%lld × %lld pixels"), Int64(width), Int64(height))
        }
        return nil
    }

    private static func virtualDisplayStatus(
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

    private static func virtualDisplayRuntimeStatus(
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

    private static func virtualDisplayFailureReason(
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

    private static func hasActiveVirtualDisplayAttempt(
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

    private static func latestVirtualDisplayLifecycleTrace(
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

    private static func previewStatus(
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

    private static func lanWebViewStatus(
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

    private static func issueStatus(for lastFailureCode: String?) -> (value: String, tone: DisplaySurfaceStatusTone)? {
        guard let lastFailureCode else {
            return nil
        }
        if lastFailureCode.hasPrefix("startup_restore_") || lastFailureCode.hasPrefix("virtual_display_") {
            return (String(localized: "Startup Failed"), .danger)
        }
        return (String(localized: "Failed"), .danger)
    }

    private static func rowActions(
        isPreviewing: Bool,
        isSharing: Bool,
        canStopPreview: Bool,
        canStopLANWebViewSharing: Bool
    ) -> [DisplaySurfaceRowActionPresentation] {
        [
            isPreviewing
                ? DisplaySurfaceRowActionPresentation(
                    kind: .stopPreview,
                    title: String(localized: "Stop"),
                    help: String(localized: "Stop Preview"),
                    systemImage: "stop.circle",
                    accessibilityIdentifier: "displays_action_stop_preview",
                    isEnabled: canStopPreview,
                    isDestructive: true
                )
                : DisplaySurfaceRowActionPresentation(
                    kind: .openPreview,
                    title: String(localized: "Preview"),
                    systemImage: "dot.scope.display",
                    accessibilityIdentifier: "displays_action_open_preview",
                    isEnabled: true
                ),
            isSharing
                ? DisplaySurfaceRowActionPresentation(
                    kind: .stopLANWebView,
                    title: String(localized: "Stop"),
                    help: String(localized: "Stop Sharing"),
                    systemImage: "stop.circle",
                    accessibilityIdentifier: "displays_action_stop_lan_web_view",
                    isEnabled: canStopLANWebViewSharing,
                    isDestructive: true
                )
                : DisplaySurfaceRowActionPresentation(
                    kind: .openLANWebView,
                    title: String(localized: "Sharing"),
                    help: String(localized: "Sharing"),
                    systemImage: "network",
                    accessibilityIdentifier: "displays_action_open_lan_web_view",
                    isEnabled: true
                )
        ]
    }

    private static func accessibilitySummary(
        title: String,
        statusItems: [DisplaySurfaceStatusItemPresentation]
    ) -> String {
        let statuses = statusItems
            .map { "\($0.title): \($0.value)" }
            .joined(separator: ", ")
        return "\(title), \(statuses)"
    }

    private static func captureStateStatus(
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

    private static func runtimeAttachmentStatus(_ leases: [DisplayRuntimeConsumerLeaseSnapshot]) -> String {
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

    private static func lastFailureCode(
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

    private static func reasonText(_ reason: DisplayRuntimeCaptureIntentReason) -> String {
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

    private static func outcomeText(_ outcome: DisplayRuntimeCaptureIntentApplyOutcome) -> String {
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
