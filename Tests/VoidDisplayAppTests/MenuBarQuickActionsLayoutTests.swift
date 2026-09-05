@testable import VoidDisplayApp
import AppKit
import SwiftUI
import Testing

@MainActor
struct MenuBarQuickActionsLayoutTests {
    @Test
    func headerFitsOneCompactUtilityRow() {
        let view = MenuBarQuickActionsHeader(
            summary: HomeRuntimeSummaryPresentation(
                virtualDisplayCount: 3,
                runningVirtualDisplayCount: 1,
                previewingCount: 0,
                sharingCount: 0,
                activeViewerCount: 0
            ),
            openMainWindow: {}
        )
        let hostingView = NSHostingView(rootView: view)

        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize.height <= 28)
    }

    @Test
    func quickActionLabelShowsItsTitle() {
        let view = MenuBarQuickActionLabel(
            title: "Preview",
            systemImage: "dot.scope.display",
            isWorking: false
        )
        let hostingView = NSHostingView(rootView: view)

        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize.width >= 56)
    }

    @Test
    func fullyActionableRowFitsCompactPanelHeight() {
        let view = MenuBarVirtualDisplayRow(
            state: makeRowState(),
            performAction: { _ in }
        )
        .frame(width: 308)
        let hostingView = NSHostingView(rootView: view)

        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize.height <= 80)
    }

    private func makeRowState() -> HomeVirtualDisplayItemRenderState {
        HomeVirtualDisplayItemRenderState(
            item: HomeVirtualDisplayItemPresentation(
                id: UUID(),
                displayID: 9_901,
                shareAddress: "http://127.0.0.1:8089/display/9901",
                title: "Virtual Display 13-inch",
                subtitle: "Serial Number: 1 · 1440 × 900",
                desiredEnabled: true,
                isRunning: true,
                isPreviewing: false,
                isSharing: true,
                viewerCount: 0,
                statusLabel: "Enabled · Running",
                statusTone: .success,
                hasIssue: false,
                compactStatusItems: [],
                operationalStatusItems: [],
                accessibilitySummary: "Virtual Display 13-inch, Enabled and running"
            ),
            isFirst: true,
            isLast: true,
            isToggling: false,
            isRebuilding: false,
            hasRecentApplySuccess: false,
            rebuildFailureMessage: nil,
            isPrimary: false,
            canSetAsPrimary: false,
            needsDisplayDetection: false,
            isDisplayDetectionScanning: false,
            isPreviewActionDisabled: false,
            isPreviewStarting: false,
            isWebViewActionDisabled: false,
            isWebViewStarting: false
        )
    }
}
