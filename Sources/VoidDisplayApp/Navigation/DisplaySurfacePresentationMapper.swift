import CoreGraphics
import Foundation
import VoidDisplayRuntime
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
        let runtimeConsumerKinds = DisplaySurfaceStatusPresentation.runtimeConsumerKinds(
            aggregate: aggregate,
            effectiveIntent: effectiveIntent
        )
        let lastFailureCode = DisplaySurfaceStatusPresentation.lastFailureCode(
            surface: surface,
            leases: leases,
            effectiveIntent: effectiveIntent,
            sharing: snapshot.sharing,
            snapshot: snapshot
        )
        let isPreviewing = DisplaySurfaceStatusPresentation.hasRuntimeDemand(
            kind: .preview,
            leases: previewLeases,
            runtimeConsumerKinds: runtimeConsumerKinds
        )
        let isSharing = DisplaySurfaceStatusPresentation.hasRuntimeDemand(
            kind: .lanWebView,
            leases: lanWebViewLeases,
            runtimeConsumerKinds: runtimeConsumerKinds
        )
        let viewerCount = max(surface.sharing?.viewerCount ?? 0, aggregate?.activeViewerCount ?? 0)
        let title = DisplaySurfaceIdentityPresentation.title(
            for: surface,
            ordinal: ordinal,
            virtualDisplayNamesByConfigID: virtualDisplayNamesByConfigID
        )
        let subtitle = DisplaySurfaceIdentityPresentation.subtitle(for: surface)
        let virtualDisplayStatus = DisplaySurfaceStatusPresentation.virtualDisplayStatus(
            for: surface,
            snapshot: snapshot
        )
        let previewStatus = DisplaySurfaceStatusPresentation.previewStatus(
            leases: previewLeases,
            hasRuntimeDemand: isPreviewing
        )
        let lanWebViewStatus = DisplaySurfaceStatusPresentation.lanWebViewStatus(
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
        if let issueStatus = DisplaySurfaceStatusPresentation.issueStatus(for: lastFailureCode) {
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
        let rowActions = DisplaySurfaceActionPresentation.rowActions(
            isPreviewing: isPreviewing,
            isSharing: isSharing,
            canStopPreview: canStopPreview,
            canStopLANWebViewSharing: canStopLANWebViewSharing
        )
        let accessibilitySummary = DisplaySurfaceActionPresentation.accessibilitySummary(
            title: title,
            statusItems: compactStatusItems
        )
        let technicalStatusItems = [
            DisplaySurfaceStatusItemPresentation(
                id: "identity",
                title: String(localized: "Display Identifier"),
                value: DisplaySurfaceIdentityPresentation.redactedIdentityText(for: surface.identity),
                accessibilityIdentifier: "displays_surface_identity_value"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "captureState",
                title: String(localized: "Capture State"),
                value: DisplaySurfaceStatusPresentation.captureStateStatus(effectiveIntent),
                accessibilityIdentifier: "displays_capture_state_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "lease",
                title: String(localized: "Runtime Attachment"),
                value: DisplaySurfaceStatusPresentation.runtimeAttachmentStatus(leases),
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
}
