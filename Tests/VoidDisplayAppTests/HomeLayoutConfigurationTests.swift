@testable import VoidDisplayApp
import SwiftUI
import Testing
import VoidDisplayDesignSystem

struct HomeLayoutMetricsTests {
    @Test func currentMetricsOwnHomeSurfaceSpacing() {
        let metrics = HomeLayoutMetrics.current

        #expect(metrics.itemHorizontalPadding == AppUI.Spacing.large)
        #expect(metrics.itemVerticalPadding == AppUI.List.rowVerticalInset)
        #expect(metrics.itemCornerRadius == 8)
        #expect(metrics.itemSpacing == AppUI.List.sectionSpacing)
        #expect(metrics.contentMaxWidth == 1240)
    }
}

@MainActor
struct HomeVirtualDisplayOperationalToggleLayoutTests {
    @Test func startingStateKeepsControlWidthStableAcrossRuntimeTones() {
        let controls = [
            (title: "Preview", systemImage: "dot.scope.display"),
            (title: "Web Sharing", systemImage: "network")
        ]
        let tones: [DisplaySurfaceStatusTone] = [.neutral, .warning, .danger]

        for control in controls {
            let idleWidth = fittingWidth(
                title: control.title,
                systemImage: control.systemImage,
                tone: .neutral,
                isStarting: false
            )

            for tone in tones {
                let startingWidth = fittingWidth(
                    title: control.title,
                    systemImage: control.systemImage,
                    tone: tone,
                    isStarting: true
                )
                #expect(abs(startingWidth - idleWidth) < 1)
            }
        }
    }

    @Test func nonStartingRuntimeTonesKeepControlWidthStable() {
        let neutralWidth = fittingWidth(value: "Off", tone: .neutral, isStarting: false)
        let runtimeStates: [(value: String, tone: DisplaySurfaceStatusTone)] = [
            ("Restarting", .warning),
            ("Draining", .warning),
            ("Failed", .danger)
        ]

        for state in runtimeStates {
            let stateWidth = fittingWidth(
                value: state.value,
                tone: state.tone,
                isStarting: false
            )
            #expect(abs(stateWidth - neutralWidth) < 1)
        }
    }

    private func fittingWidth(
        title: String = "Web Sharing",
        systemImage: String = "network",
        value: String = "Stopped",
        tone: DisplaySurfaceStatusTone,
        isStarting: Bool
    ) -> CGFloat {
        let view = HomeVirtualDisplayOperationalToggle(
            statusItem: DisplaySurfaceStatusItemPresentation(
                id: "webView",
                title: title,
                value: value,
                accessibilityIdentifier: "web_sharing_status",
                tone: tone
            ),
            systemImage: systemImage,
            isOn: false,
            isStarting: isStarting,
            isDisabled: isStarting,
            accessibilityIdentifier: "web_sharing_toggle",
            onToggle: {}
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.width
    }
}

@MainActor
struct HomeVirtualDisplayItemCopyShareAddressLabelLayoutTests {
    @Test func confirmationKeepsCopyActionWidthStable() {
        let copyWidth = fittingWidth(isShowingConfirmation: false)
        let confirmationWidth = fittingWidth(isShowingConfirmation: true)

        #expect(abs(copyWidth - confirmationWidth) < 1)
    }

    private func fittingWidth(isShowingConfirmation: Bool) -> CGFloat {
        let view = HomeVirtualDisplayItemCopyShareAddressLabel(
            isShowingConfirmation: isShowingConfirmation
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.width
    }
}

@MainActor
struct HomeSummaryStatusItemLayoutTests {
    @Test func zeroThroughTwoDigitCountsKeepFollowingMetricPositionStable() {
        let baselineWidth = fittingWidth(value: "0", isActive: false)

        for value in ["1", "9", "10", "88"] {
            let width = fittingWidth(value: value, isActive: true)
            #expect(abs(width - baselineWidth) < 0.1)
        }

        #expect(fittingWidth(value: "100", isActive: true) > baselineWidth)
    }

    private func fittingWidth(value: String, isActive: Bool) -> CGFloat {
        let view = HomeSummaryStatusItem(
            title: "Web Sharing",
            value: value,
            systemImage: "network",
            tint: isActive ? .green : .secondary,
            isActive: isActive,
            minimumValueDigitCount: 2
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.width
    }
}

@MainActor
struct HomeSharingPortApplyButtonLayoutTests {
    @Test func dirtyStateKeepsFollowingPortBadgePositionStable() {
        let idleWidth = fittingWidth(isVisible: false)
        let dirtyWidth = fittingWidth(isVisible: true)

        #expect(abs(idleWidth - dirtyWidth) < 0.1)
    }

    private func fittingWidth(isVisible: Bool) -> CGFloat {
        let view = HomeSharingPortApplyButton(isVisible: isVisible, action: {})
        let hostingView = NSHostingView(rootView: view)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.width
    }
}
