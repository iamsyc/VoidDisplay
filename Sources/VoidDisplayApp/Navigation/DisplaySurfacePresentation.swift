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
    package let kindText: String
    package let isManagedVirtualDisplay: Bool
    package let isMonitoring: Bool
    package let isSharing: Bool
    package let hasFailure: Bool
    package let canStopMonitor: Bool
    package let canStopLANWebViewSharing: Bool
    package let canStopWebService: Bool
    package let statusItems: [DisplaySurfaceStatusItemPresentation]

    package init(
        id: String,
        surfaceIdentity: DisplaySurfaceIdentity,
        displayID: CGDirectDisplayID?,
        title: String,
        subtitle: String,
        kindText: String,
        isManagedVirtualDisplay: Bool,
        isMonitoring: Bool,
        isSharing: Bool,
        hasFailure: Bool,
        canStopMonitor: Bool,
        canStopLANWebViewSharing: Bool,
        canStopWebService: Bool,
        statusItems: [DisplaySurfaceStatusItemPresentation]
    ) {
        self.id = id
        self.surfaceIdentity = surfaceIdentity
        self.displayID = displayID
        self.title = title
        self.subtitle = subtitle
        self.kindText = kindText
        self.isManagedVirtualDisplay = isManagedVirtualDisplay
        self.isMonitoring = isMonitoring
        self.isSharing = isSharing
        self.hasFailure = hasFailure
        self.canStopMonitor = canStopMonitor
        self.canStopLANWebViewSharing = canStopLANWebViewSharing
        self.canStopWebService = canStopWebService
        self.statusItems = statusItems
    }
}

package struct DisplaySurfaceStatusItemPresentation: Identifiable, Equatable {
    package let id: String
    package let title: String
    package let value: String
    package let accessibilityIdentifier: String
    package let isFailureCode: Bool

    package init(
        id: String,
        title: String,
        value: String,
        accessibilityIdentifier: String,
        isFailureCode: Bool = false
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isFailureCode = isFailureCode
    }
}

package enum DisplaySurfacePresentationMapper {
    package static func makePresentation(snapshot: DisplayRuntimeSnapshot) -> DisplaySurfaceListPresentation {
        let surfaces = snapshot.surfaces.map { surface in
            makeSurfacePresentation(surface: surface, snapshot: snapshot)
        }
        return DisplaySurfaceListPresentation(surfaces: surfaces)
    }

    private static func makeSurfacePresentation(
        surface: DisplaySurface,
        snapshot: DisplayRuntimeSnapshot
    ) -> DisplaySurfacePresentation {
        let leases = snapshot.consumerLeases.filter { $0.surfaceIdentity == surface.identity }
        let aggregate = snapshot.aggregatedDemands.first { $0.surfaceIdentity == surface.identity }
        let effectiveIntent = snapshot.effectiveCaptureIntents.last { $0.intent.surfaceIdentity == surface.identity }
        let monitorLeases = leases.filter { $0.kind == .monitor }
        let lanWebViewLeases = leases.filter { $0.kind == .lanWebView }
        let runtimeConsumerKinds = runtimeConsumerKinds(
            aggregate: aggregate,
            effectiveIntent: effectiveIntent
        )
        let lastFailureCode = lastFailureCode(
            surface: surface,
            leases: leases,
            effectiveIntent: effectiveIntent,
            sharing: snapshot.sharing
        )
        let isMonitoring = hasRuntimeDemand(
            kind: .monitor,
            leases: monitorLeases,
            runtimeConsumerKinds: runtimeConsumerKinds
        )
        let isSharing = hasRuntimeDemand(
            kind: .lanWebView,
            leases: lanWebViewLeases,
            runtimeConsumerKinds: runtimeConsumerKinds
        )
        let viewerCount = max(surface.sharing?.viewerCount ?? 0, aggregate?.activeViewerCount ?? 0)
        let title = title(for: surface)
        let subtitle = subtitle(for: surface)
        let kindText = kindText(for: surface)
        let statusItems = [
            DisplaySurfaceStatusItemPresentation(
                id: "kind",
                title: String(localized: "Display Type"),
                value: kindText,
                accessibilityIdentifier: "displays_surface_kind_value"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "identity",
                title: String(localized: "Display Identity"),
                value: redactedIdentityText(for: surface.identity),
                accessibilityIdentifier: "displays_surface_identity_value"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "virtualDisplay",
                title: String(localized: "Virtual Display"),
                value: virtualDisplayStatus(for: surface.managedVirtualDisplay),
                accessibilityIdentifier: "displays_virtual_display_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "monitor",
                title: String(localized: "Monitor Consumer"),
                value: consumerStatus(
                    leases: monitorLeases,
                    hasRuntimeDemand: isMonitoring
                ),
                accessibilityIdentifier: "displays_monitor_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "lanWebView",
                title: String(localized: "LAN Web View Consumer"),
                value: lanWebViewStatus(
                    surface: surface,
                    leases: lanWebViewLeases,
                    hasRuntimeDemand: isSharing
                ),
                accessibilityIdentifier: "displays_lan_web_view_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "viewerCount",
                title: String(localized: "Active Viewers"),
                value: String(viewerCount),
                accessibilityIdentifier: "displays_viewer_count"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "captureIntent",
                title: String(localized: "Effective Capture Intent"),
                value: effectiveCaptureIntentStatus(effectiveIntent),
                accessibilityIdentifier: "displays_capture_intent_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "lease",
                title: String(localized: "Lease Status"),
                value: leaseStatus(leases),
                accessibilityIdentifier: "displays_lease_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "lastFailureCode",
                title: String(localized: "Last Failure Code"),
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
            kindText: kindText,
            isManagedVirtualDisplay: surface.kind == .managedVirtualDisplay,
            isMonitoring: isMonitoring,
            isSharing: isSharing,
            hasFailure: lastFailureCode != nil,
            canStopMonitor: surface.currentDisplayID != nil
                && monitorLeases.contains { $0.state.contributesDemand },
            canStopLANWebViewSharing: surface.currentDisplayID != nil
                && lanWebViewLeases.contains { $0.state.contributesDemand },
            canStopWebService: snapshot.sharing.isWebServiceRunning,
            statusItems: statusItems
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

    private static func title(for surface: DisplaySurface) -> String {
        switch surface.kind {
        case .managedVirtualDisplay:
            String(localized: "Managed Virtual Display")
        case .physicalDisplay:
            String(localized: "Physical Auxiliary Display")
        }
    }

    private static func subtitle(for surface: DisplaySurface) -> String {
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
        return String(localized: "Runtime display status")
    }

    private static func kindText(for surface: DisplaySurface) -> String {
        switch surface.kind {
        case .managedVirtualDisplay:
            String(localized: "Managed virtual")
        case .physicalDisplay:
            String(localized: "Physical auxiliary")
        }
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

    private static func virtualDisplayStatus(
        for state: DisplayRuntimeManagedVirtualDisplaySurfaceState?
    ) -> String {
        guard let state else {
            return String(localized: "Not managed")
        }

        let desired: String
        switch state.desiredEnabled {
        case true:
            desired = String(localized: "Enabled")
        case false:
            desired = String(localized: "Disabled")
        case nil:
            desired = String(localized: "Desired state unknown")
        }

        let runtime = state.isLiveRuntime
            ? String(localized: "Live")
            : state.isRunning
                ? String(localized: "Running")
                : String(localized: "Not live")
        let rebuild = state.isRebuilding
            ? String(localized: "Rebuilding")
            : String(localized: "Idle")
        return [desired, runtime, rebuild].joined(separator: ", ")
    }

    private static func consumerStatus(
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        hasRuntimeDemand: Bool
    ) -> String {
        if leases.contains(where: { $0.state == .failed }) {
            return String(localized: "Failed")
        }
        if leases.contains(where: { $0.state == .restarting }) {
            return String(localized: "Restarting")
        }
        if leases.contains(where: { $0.state == .draining }) {
            return String(localized: "Draining")
        }
        if hasRuntimeDemand {
            return String(localized: "Attached")
        }
        return String(localized: "Inactive")
    }

    private static func lanWebViewStatus(
        surface: DisplaySurface,
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        hasRuntimeDemand: Bool
    ) -> String {
        let status = consumerStatus(
            leases: leases,
            hasRuntimeDemand: hasRuntimeDemand
        )
        guard status == String(localized: "Inactive"), surface.sharing?.hasRoute == true else {
            return status
        }
        return String(localized: "Route ready")
    }

    private static func effectiveCaptureIntentStatus(
        _ effectiveIntent: DisplayRuntimeEffectiveCaptureIntent?
    ) -> String {
        guard let effectiveIntent else {
            return String(localized: "No intent")
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

    private static func leaseStatus(_ leases: [DisplayRuntimeConsumerLeaseSnapshot]) -> String {
        guard leases.isEmpty == false else {
            return String(localized: "No leases")
        }
        let activeCount = leases.filter { $0.state.contributesDemand }.count
        return String(
            format: String(localized: "%lld of %lld active leases"),
            Int64(activeCount),
            Int64(leases.count)
        )
    }

    private static func lastFailureCode(
        surface: DisplaySurface,
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        effectiveIntent: DisplayRuntimeEffectiveCaptureIntent?,
        sharing: DisplayRuntimeSharingSnapshot
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
        if surface.managedVirtualDisplay?.hasRebuildFailure == true {
            return "virtual_display_rebuild_failed"
        }
        if surface.managedVirtualDisplay?.hasRestoreFailure == true {
            return "virtual_display_restore_failed"
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
