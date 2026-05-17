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
    package let recentFailureCount: Int
    package let lastFailureCode: String?

    package init(
        virtualDisplayCount: Int,
        runningVirtualDisplayCount: Int,
        previewingCount: Int,
        sharingCount: Int,
        activeViewerCount: Int,
        recentFailureCount: Int,
        lastFailureCode: String?
    ) {
        self.virtualDisplayCount = virtualDisplayCount
        self.runningVirtualDisplayCount = runningVirtualDisplayCount
        self.previewingCount = previewingCount
        self.sharingCount = sharingCount
        self.activeViewerCount = activeViewerCount
        self.recentFailureCount = recentFailureCount
        self.lastFailureCode = lastFailureCode
    }
}

package struct HomeVirtualDisplayCardPresentation: Identifiable, Equatable {
    package let id: UUID
    package let displayID: CGDirectDisplayID?
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
    package let accessibilitySummary: String

    package init(
        id: UUID,
        displayID: CGDirectDisplayID?,
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
        accessibilitySummary: String
    ) {
        self.id = id
        self.displayID = displayID
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
        self.accessibilitySummary = accessibilitySummary
    }
}

package enum HomeVirtualDisplayPresentationMapper {
    package static func makePresentation(
        snapshot: DisplayRuntimeSnapshot,
        displayConfigs: [VirtualDisplayConfig]
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
                runtimeSurface: runtimeSurfacesByConfigID[config.id]
            )
        }
        let configIDs = Set(displayConfigs.map(\.id))
        return HomeVirtualDisplaySurfacePresentation(
            summary: makeSummary(snapshot: snapshot, cards: cards, configIDs: configIDs),
            cards: cards
        )
    }

    private static func makeCard(
        config: VirtualDisplayConfig,
        surface: DisplaySurfacePresentation?,
        runtimeSurface: DisplaySurface?
    ) -> HomeVirtualDisplayCardPresentation {
        let virtualDisplayStatus = surface?.compactStatusItems.first { $0.id == "virtualDisplay" }
        let hasIssue = surface?.compactStatusItems.contains { $0.id == "issue" } ?? false
        let viewerCount = surface?.compactStatusItems.first { $0.id == "viewerCount" }
            .flatMap { Int($0.value) } ?? 0
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
            displayID: surface?.displayID,
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
            compactStatusItems: surface?.compactStatusItems ?? fallbackStatusItems(for: config),
            accessibilitySummary: surface?.accessibilitySummary ?? "\(config.displayName), \(statusLabel)"
        )
    }

    private static func makeSummary(
        snapshot: DisplayRuntimeSnapshot,
        cards: [HomeVirtualDisplayCardPresentation],
        configIDs: Set<UUID>
    ) -> HomeRuntimeSummaryPresentation {
        HomeRuntimeSummaryPresentation(
            virtualDisplayCount: cards.count,
            runningVirtualDisplayCount: cards.count { $0.isRunning },
            previewingCount: cards.count { $0.isPreviewing },
            sharingCount: cards.count { $0.isSharing },
            activeViewerCount: cards.reduce(0) { $0 + $1.viewerCount },
            recentFailureCount: recentFailureCount(snapshot: snapshot, cards: cards, configIDs: configIDs),
            lastFailureCode: latestFailureCode(snapshot: snapshot, configIDs: configIDs)
        )
    }

    private static func statusLabel(
        config: VirtualDisplayConfig,
        surface: DisplaySurfacePresentation?,
        virtualDisplayStatus: DisplaySurfaceStatusItemPresentation?,
        hasIssue: Bool
    ) -> String {
        if hasIssue {
            return String(localized: "Needs attention")
        }
        if let virtualDisplayStatus {
            return virtualDisplayStatus.value
        }
        return config.desiredEnabled ? String(localized: "Enabled") : String(localized: "Disabled")
    }

    private static func statusTone(
        config: VirtualDisplayConfig,
        surface _: DisplaySurfacePresentation?,
        virtualDisplayStatus: DisplaySurfaceStatusItemPresentation?,
        hasIssue: Bool
    ) -> DisplaySurfaceStatusTone {
        if hasIssue {
            return .danger
        }
        if let virtualDisplayStatus {
            return virtualDisplayStatus.tone
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

    private static func recentFailureCount(
        snapshot: DisplayRuntimeSnapshot,
        cards: [HomeVirtualDisplayCardPresentation],
        configIDs: Set<UUID>
    ) -> Int {
        let transactionFailures = snapshot.transactions.recentTransactions.count {
            isTransactionRelevant($0, configIDs: configIDs) &&
                ($0.failure != nil || $0.compensation.failureReason != nil)
        }
        let intentFailures = snapshot.effectiveCaptureIntents.count {
            isManagedIdentity($0.intent.surfaceIdentity, in: configIDs) &&
                ($0.lastFailureCode != nil ||
                $0.lastApplyResult?.failureCode != nil ||
                    $0.intent.lastFailureCode != nil)
        }
        let leaseFailures = snapshot.consumerLeases.count {
            isManagedIdentity($0.surfaceIdentity, in: configIDs) && $0.lastFailureCode != nil
        }
        let surfaceFailures = snapshot.surfaces.count {
            guard isCurrentManagedSurface($0, configIDs: configIDs) else { return false }
            return $0.managedVirtualDisplay?.hasRebuildFailure == true ||
                $0.managedVirtualDisplay?.hasRestoreFailure == true
        }
        let sharingLifecycleFailures = hasCurrentSharingLifecycleFailure(
            snapshot: snapshot,
            configIDs: configIDs
        ) ? 1 : 0
        let runtimeFailureCount = transactionFailures + intentFailures + leaseFailures +
            surfaceFailures + sharingLifecycleFailures
        let issueCardCount = cards.count { $0.hasIssue }
        return max(runtimeFailureCount, issueCardCount)
    }

    private static func latestFailureCode(
        snapshot: DisplayRuntimeSnapshot,
        configIDs: Set<UUID>
    ) -> String? {
        let transactionsByRecency =
            Array(snapshot.transactions.recentTransactions.reversed()) +
            Array(snapshot.transactions.activeTransactions.reversed())
        for transaction in transactionsByRecency {
            guard isTransactionRelevant(transaction, configIDs: configIDs) else { continue }
            if let reason = transaction.failure?.reason {
                return reason
            }
            if let reason = transaction.compensation.failureReason {
                return reason
            }
        }

        for intent in snapshot.effectiveCaptureIntents.reversed() {
            guard isManagedIdentity(intent.intent.surfaceIdentity, in: configIDs) else { continue }
            if let code = intent.lastFailureCode ?? intent.lastApplyResult?.failureCode ?? intent.intent.lastFailureCode {
                return code
            }
        }

        for surface in snapshot.surfaces {
            guard isCurrentManagedSurface(surface, configIDs: configIDs) else { continue }
            if surface.managedVirtualDisplay?.hasRebuildFailure == true {
                return "virtual_display_rebuild_failed"
            }
            if surface.managedVirtualDisplay?.hasRestoreFailure == true {
                return "virtual_display_restore_failed"
            }
        }

        if hasCurrentSharingLifecycleFailure(snapshot: snapshot, configIDs: configIDs),
           let reason = snapshot.sharing.lifecycle.failureReason {
            return reason
        }

        return snapshot.consumerLeases.reversed().compactMap {
            isManagedIdentity($0.surfaceIdentity, in: configIDs) ? $0.lastFailureCode : nil
        }.first
    }

    private static func isCurrentManagedSurface(
        _ surface: DisplaySurface,
        configIDs: Set<UUID>
    ) -> Bool {
        configID(for: surface).map(configIDs.contains) ?? false
    }

    private static func isManagedIdentity(
        _ identity: DisplaySurfaceIdentity,
        in configIDs: Set<UUID>
    ) -> Bool {
        guard identity.kind == .managedVirtualDisplay,
              let configID = UUID(uuidString: identity.stableID) else {
            return false
        }
        return configIDs.contains(configID)
    }

    private static func isTransactionRelevant(
        _ trace: DisplayRuntimeTransactionTrace,
        configIDs: Set<UUID>
    ) -> Bool {
        if trace.targetConfigID.map(configIDs.contains) == true {
            return true
        }
        if trace.createdConfigID.map(configIDs.contains) == true {
            return true
        }
        if (trace.startupRestoreIntent?.configID).map(configIDs.contains) == true {
            return true
        }
        if (trace.startupRestoreCommandResult?.configID).map(configIDs.contains) == true {
            return true
        }
        return trace.affectedSurfaces.contains { surface in
            configIDs.contains(surface.configID) || isManagedIdentity(surface.identity, in: configIDs)
        }
    }

    private static func hasCurrentSharingLifecycleFailure(
        snapshot: DisplayRuntimeSnapshot,
        configIDs: Set<UUID>
    ) -> Bool {
        guard snapshot.sharing.lifecycle.phase == .failed,
              snapshot.sharing.lifecycle.failureReason != nil else {
            return false
        }
        return snapshot.surfaces.contains { surface in
            isCurrentManagedSurface(surface, configIDs: configIDs) && surface.sharing != nil
        }
    }
}
