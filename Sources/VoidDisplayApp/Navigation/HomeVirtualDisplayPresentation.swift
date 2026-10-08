import CoreGraphics
import Foundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay

package struct HomeVirtualDisplaySurfacePresentation: Equatable {
    package let summary: HomeRuntimeSummaryPresentation
    package let items: [HomeVirtualDisplayItemPresentation]

    package init(
        summary: HomeRuntimeSummaryPresentation,
        items: [HomeVirtualDisplayItemPresentation]
    ) {
        self.summary = summary
        self.items = items
    }
}

package struct HomeRuntimeSummaryPresentation: Equatable {
    package let virtualDisplayCount: Int
    package let runningVirtualDisplayCount: Int
    package let previewingCount: Int
    package let sharingCount: Int
    package let activeViewerCount: Int

    package init(
        virtualDisplayCount: Int,
        runningVirtualDisplayCount: Int,
        previewingCount: Int,
        sharingCount: Int,
        activeViewerCount: Int
    ) {
        self.virtualDisplayCount = virtualDisplayCount
        self.runningVirtualDisplayCount = runningVirtualDisplayCount
        self.previewingCount = previewingCount
        self.sharingCount = sharingCount
        self.activeViewerCount = activeViewerCount
    }
}

package struct HomeVirtualDisplayItemPresentation: Identifiable, Equatable {
    package let id: UUID
    package let displayID: CGDirectDisplayID?
    package let shareAddress: String?
    package let title: String
    package let subtitle: String
    package let desiredEnabled: Bool
    package let isRunning: Bool
    package let isPreviewing: Bool
    package let isSharing: Bool
    package let viewerCount: Int
    package let statusLabel: String
    package let statusTone: DisplaySurfaceStatusTone
    package let hasIssue: Bool
    package let compactStatusItems: [DisplaySurfaceStatusItemPresentation]
    package let operationalStatusItems: [DisplaySurfaceStatusItemPresentation]
    package let accessibilitySummary: String

    package init(
        id: UUID,
        displayID: CGDirectDisplayID?,
        shareAddress: String?,
        title: String,
        subtitle: String,
        desiredEnabled: Bool,
        isRunning: Bool,
        isPreviewing: Bool,
        isSharing: Bool,
        viewerCount: Int,
        statusLabel: String,
        statusTone: DisplaySurfaceStatusTone,
        hasIssue: Bool,
        compactStatusItems: [DisplaySurfaceStatusItemPresentation],
        operationalStatusItems: [DisplaySurfaceStatusItemPresentation],
        accessibilitySummary: String
    ) {
        self.id = id
        self.displayID = displayID
        self.shareAddress = shareAddress
        self.title = title
        self.subtitle = subtitle
        self.desiredEnabled = desiredEnabled
        self.isRunning = isRunning
        self.isPreviewing = isPreviewing
        self.isSharing = isSharing
        self.viewerCount = viewerCount
        self.statusLabel = statusLabel
        self.statusTone = statusTone
        self.hasIssue = hasIssue
        self.compactStatusItems = compactStatusItems
        self.operationalStatusItems = operationalStatusItems
        self.accessibilitySummary = accessibilitySummary
    }
}

package enum HomeVirtualDisplayPresentationMapper {
    package static func makePresentation(
        snapshot: DisplayRuntimeSnapshot,
        displayConfigs: [VirtualDisplayConfig],
        sharePageAddresses: [CGDirectDisplayID: String] = [:]
    ) -> HomeVirtualDisplaySurfacePresentation {
        let managedSurfaces = snapshot.surfaces.filter { $0.kind == .managedVirtualDisplay }
        let surfacesByConfigID = Dictionary(
            managedSurfaces.compactMap { surface in
                surface.managedVirtualDisplay.map { ($0.configID, surface) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let leasesBySurface = Dictionary(grouping: snapshot.consumerLeases, by: \.surfaceIdentity)
        let demandsBySurface = Dictionary(
            snapshot.aggregatedDemands.map { ($0.surfaceIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let intentsBySurface = Dictionary(
            snapshot.effectiveCaptureIntents.map { ($0.intent.surfaceIdentity, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let ordinalsByIdentity = Dictionary(
            managedSurfaces.enumerated().map { ($0.element.identity, $0.offset + 1) },
            uniquingKeysWith: { first, _ in first }
        )
        let items = displayConfigs.map { config in
            let surface = surfacesByConfigID[config.id]
            let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: config.id)
            return makeItem(
                config: config,
                surface: surface,
                snapshot: snapshot,
                leases: leasesBySurface[identity] ?? [],
                aggregate: demandsBySurface[identity],
                effectiveIntent: intentsBySurface[identity],
                ordinal: managedSurfaces.count > 1
                    ? ordinalsByIdentity[identity]
                    : nil,
                sharePageAddresses: sharePageAddresses
            )
        }
        return HomeVirtualDisplaySurfacePresentation(
            summary: HomeRuntimeSummaryPresentation(
                virtualDisplayCount: items.count,
                runningVirtualDisplayCount: items.count { $0.isRunning },
                previewingCount: items.count { $0.isPreviewing },
                sharingCount: items.count { $0.isSharing },
                activeViewerCount: items.reduce(0) { $0 + $1.viewerCount }
            ),
            items: items
        )
    }

    private static func makeItem(
        config: VirtualDisplayConfig,
        surface: DisplaySurface?,
        snapshot: DisplayRuntimeSnapshot,
        leases: [DisplayRuntimeConsumerLeaseSnapshot],
        aggregate: DisplayRuntimeAggregatedDemand?,
        effectiveIntent: DisplayRuntimeEffectiveCaptureIntent?,
        ordinal: Int?,
        sharePageAddresses: [CGDirectDisplayID: String]
    ) -> HomeVirtualDisplayItemPresentation {
        let previewLeases = leases.filter { $0.kind == .preview }
        let lanWebViewLeases = leases.filter { $0.kind == .lanWebView }
        let runtimeConsumerKinds = DisplaySurfaceStatusPresentation.runtimeConsumerKinds(
            aggregate: aggregate, effectiveIntent: effectiveIntent
        )
        let isPreviewing = surface != nil && DisplaySurfaceStatusPresentation.hasRuntimeDemand(
            kind: .preview, leases: previewLeases, runtimeConsumerKinds: runtimeConsumerKinds
        )
        let isSharing = surface != nil && DisplaySurfaceStatusPresentation.hasRuntimeDemand(
            kind: .lanWebView, leases: lanWebViewLeases, runtimeConsumerKinds: runtimeConsumerKinds
        )
        let lastFailureCode = surface.flatMap {
            DisplaySurfaceStatusPresentation.lastFailureCode(
                surface: $0, leases: leases, effectiveIntent: effectiveIntent,
                sharing: snapshot.sharing, snapshot: snapshot
            )
        }
        let virtualDisplayStatus = surface.flatMap {
            DisplaySurfaceStatusPresentation.virtualDisplayStatus(for: $0, snapshot: snapshot)
        }
        let previewStatus = DisplaySurfaceStatusPresentation.previewStatus(
            leases: previewLeases, hasRuntimeDemand: isPreviewing
        )
        let lanWebViewStatus = DisplaySurfaceStatusPresentation.lanWebViewStatus(
            leases: lanWebViewLeases, hasRuntimeDemand: isSharing
        )
        let viewerCount = surface == nil ? 0 : max(surface?.sharing?.viewerCount ?? 0, aggregate?.activeViewerCount ?? 0)
        var compactStatusItems: [DisplaySurfaceStatusItemPresentation] = []
        if surface == nil {
            compactStatusItems = fallbackStatusItems(for: config)
        } else {
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
                    title: String(localized: "Connections"),
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
        }
        let hasIssue = compactStatusItems.contains { $0.id == "issue" }
        let statusLabel = virtualDisplayStatus?.value
            ?? (hasIssue && config.desiredEnabled
                ? "\(String(localized: "Enabled")) · \(String(localized: "Startup Failed"))"
                : config.desiredEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
        let statusTone = virtualDisplayStatus?.tone
            ?? (hasIssue ? .danger : config.desiredEnabled ? .warning : .neutral)
        let name = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = surface == nil ? config.displayName : !name.isEmpty ? name : ordinal.map {
            String(format: String(localized: "Virtual Display %lld"), Int64($0))
        } ?? String(localized: "Virtual Display")
        let accessibilitySummary = surface == nil ? "\(config.displayName), \(statusLabel)" :
            "\(title), " + compactStatusItems.filter { isSharing || $0.id != "viewerCount" }.map { item in
                item.id == "viewerCount" ? SharingConnectionText.status(viewerCount) : "\(item.title): \(item.value)"
            }.joined(separator: ", ")
        let displayID = surface?.currentDisplayID
        let isRunning = surface.map {
            $0.currentDisplayID != nil && ($0.managedVirtualDisplay?.isRunning == true || $0.managedVirtualDisplay?.isLiveRuntime == true)
        } ?? false
        return HomeVirtualDisplayItemPresentation(
            id: config.id,
            displayID: displayID,
            shareAddress: displayID.flatMap { sharePageAddresses[$0] },
            title: title,
            subtitle: VirtualDisplayRowPresentation.subtitleText(for: config),
            desiredEnabled: config.desiredEnabled,
            isRunning: isRunning,
            isPreviewing: isPreviewing,
            isSharing: isSharing,
            viewerCount: viewerCount,
            statusLabel: statusLabel,
            statusTone: statusTone,
            hasIssue: hasIssue,
            compactStatusItems: compactStatusItems,
            operationalStatusItems: compactStatusItems.filter { !["virtualDisplay", "issue"].contains($0.id) },
            accessibilitySummary: accessibilitySummary
        )
    }

    private static func fallbackStatusItems(
        for config: VirtualDisplayConfig
    ) -> [DisplaySurfaceStatusItemPresentation] {
        [
            DisplaySurfaceStatusItemPresentation(
                id: "virtualDisplay",
                title: String(localized: "Virtual Display"),
                value: config.desiredEnabled ? String(localized: "Enabled") : String(localized: "Disabled"),
                accessibilityIdentifier: "home_virtual_display_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "preview",
                title: String(localized: "Preview"),
                value: String(localized: "Off"),
                accessibilityIdentifier: "home_preview_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "webView",
                title: String(localized: "Web Sharing"),
                value: String(localized: "Off"),
                accessibilityIdentifier: "home_web_view_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "viewerCount",
                title: String(localized: "Connections"),
                value: "0",
                accessibilityIdentifier: "home_viewer_count"
            )
        ]
    }
}
