import CoreGraphics
import Foundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay

package struct HomeVirtualDisplaySurfacePresentation: Equatable {
    package let summary: HomeRuntimeSummaryPresentation
    package let cards: [HomeVirtualDisplayCardPresentation]

    package init(
        summary: HomeRuntimeSummaryPresentation,
        cards: [HomeVirtualDisplayCardPresentation]
    ) {
        self.summary = summary
        self.cards = cards
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

package struct HomeVirtualDisplayCardPresentation: Identifiable, Equatable {
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
        let namesByConfigID = Dictionary(
            uniqueKeysWithValues: displayConfigs.map { ($0.id, $0.displayName) }
        )
        let surfacePresentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: snapshot,
            virtualDisplayNamesByConfigID: namesByConfigID
        )
        let surfacesByConfigID = Dictionary(
            surfacePresentation.surfaces.compactMap { surface in
                configID(for: surface).map { ($0, surface) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let runtimeSurfacesByConfigID = Dictionary(
            snapshot.surfaces.compactMap { surface in
                configID(for: surface).map { ($0, surface) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let cards = displayConfigs.map { config in
            makeCard(
                config: config,
                surface: surfacesByConfigID[config.id],
                runtimeSurface: runtimeSurfacesByConfigID[config.id],
                sharePageAddresses: sharePageAddresses
            )
        }
        return HomeVirtualDisplaySurfacePresentation(
            summary: makeSummary(cards: cards),
            cards: cards
        )
    }

    private static func makeCard(
        config: VirtualDisplayConfig,
        surface: DisplaySurfacePresentation?,
        runtimeSurface: DisplaySurface?,
        sharePageAddresses: [CGDirectDisplayID: String]
    ) -> HomeVirtualDisplayCardPresentation {
        let virtualDisplayStatus = surface?.compactStatusItems.first { $0.id == "virtualDisplay" }
        let hasIssue = surface?.compactStatusItems.contains { $0.id == "issue" } ?? false
        let compactStatusItems = surface?.compactStatusItems ?? fallbackStatusItems(for: config)
        let viewerCount = surface?.compactStatusItems.first { $0.id == "viewerCount" }
            .flatMap { Int($0.value) } ?? 0
        let displayID = surface?.displayID
        let isRunning = runtimeSurface.map(isRunningVirtualDisplay) ?? false
        let statusLabel = statusLabel(
            config: config,
            surface: surface,
            virtualDisplayStatus: virtualDisplayStatus,
            hasIssue: hasIssue
        )
        let statusTone = statusTone(
            config: config,
            surface: surface,
            virtualDisplayStatus: virtualDisplayStatus,
            hasIssue: hasIssue
        )

        return HomeVirtualDisplayCardPresentation(
            id: config.id,
            displayID: displayID,
            shareAddress: displayID.flatMap { sharePageAddresses[$0] },
            title: surface?.title ?? config.displayName,
            subtitle: VirtualDisplayRowPresentation.subtitleText(for: config),
            desiredEnabled: config.desiredEnabled,
            isRunning: isRunning,
            isPreviewing: surface?.isPreviewing ?? false,
            isSharing: surface?.isSharing ?? false,
            viewerCount: viewerCount,
            statusLabel: statusLabel,
            statusTone: statusTone,
            hasIssue: hasIssue,
            compactStatusItems: compactStatusItems,
            operationalStatusItems: operationalStatusItems(from: compactStatusItems),
            accessibilitySummary: surface?.accessibilitySummary ?? "\(config.displayName), \(statusLabel)"
        )
    }

    private static func makeSummary(cards: [HomeVirtualDisplayCardPresentation]) -> HomeRuntimeSummaryPresentation {
        HomeRuntimeSummaryPresentation(
            virtualDisplayCount: cards.count,
            runningVirtualDisplayCount: cards.count { $0.isRunning },
            previewingCount: cards.count { $0.isPreviewing },
            sharingCount: cards.count { $0.isSharing },
            activeViewerCount: cards.reduce(0) { $0 + $1.viewerCount }
        )
    }

    private static func statusLabel(
        config: VirtualDisplayConfig,
        surface: DisplaySurfacePresentation?,
        virtualDisplayStatus: DisplaySurfaceStatusItemPresentation?,
        hasIssue: Bool
    ) -> String {
        if let virtualDisplayStatus {
            return virtualDisplayStatus.value
        }
        if hasIssue, config.desiredEnabled {
            return "\(String(localized: "Enabled")) · \(String(localized: "Startup Failed"))"
        }
        return config.desiredEnabled ? String(localized: "Enabled") : String(localized: "Disabled")
    }

    private static func statusTone(
        config: VirtualDisplayConfig,
        surface _: DisplaySurfacePresentation?,
        virtualDisplayStatus: DisplaySurfaceStatusItemPresentation?,
        hasIssue: Bool
    ) -> DisplaySurfaceStatusTone {
        if let virtualDisplayStatus {
            return virtualDisplayStatus.tone
        }
        if hasIssue {
            return .danger
        }
        return config.desiredEnabled ? .warning : .neutral
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
                title: String(localized: "Web View"),
                value: String(localized: "Off"),
                accessibilityIdentifier: "home_web_view_status"
            ),
            DisplaySurfaceStatusItemPresentation(
                id: "viewerCount",
                title: String(localized: "Viewers"),
                value: "0",
                accessibilityIdentifier: "home_viewer_count"
            )
        ]
    }

    private static func operationalStatusItems(
        from items: [DisplaySurfaceStatusItemPresentation]
    ) -> [DisplaySurfaceStatusItemPresentation] {
        items.filter { item in
            switch item.id {
            case "virtualDisplay", "issue":
                false
            default:
                true
            }
        }
    }

    private static func configID(for surface: DisplaySurfacePresentation) -> UUID? {
        guard surface.surfaceIdentity.kind == .managedVirtualDisplay else {
            return nil
        }
        return UUID(uuidString: surface.surfaceIdentity.stableID)
    }

    private static func configID(for surface: DisplaySurface) -> UUID? {
        guard surface.identity.kind == .managedVirtualDisplay || surface.kind == .managedVirtualDisplay else {
            return nil
        }
        return UUID(uuidString: surface.identity.stableID) ?? surface.managedVirtualDisplay?.configID
    }

    private static func isRunningVirtualDisplay(_ surface: DisplaySurface) -> Bool {
        guard let state = surface.managedVirtualDisplay else {
            return false
        }
        return surface.currentDisplayID != nil && (state.isRunning || state.isLiveRuntime)
    }
}
