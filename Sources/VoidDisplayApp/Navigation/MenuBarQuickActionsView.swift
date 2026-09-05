import AppKit
import SwiftUI
import VoidDisplayCapture
import VoidDisplayDesignSystem
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

@MainActor
package struct MenuBarQuickActionsView: View {
    private static let panelWidth: CGFloat = 340
    private static let visibleRowLimit = 3
    private static let scrollViewportHeight: CGFloat = 240

    @Environment(\.openWindow) private var openWindow
    @Environment(AppNavigationController.self) private var navigation

    private let virtualDisplay: VirtualDisplayController
    @State private var controller: HomeVirtualDisplaySurfaceController

    package init(
        capture: CaptureController,
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        capturePerformancePreferences: CapturePerformancePreferences,
        displayRuntime: DisplayRuntime,
        sharingAdapter: DisplayRuntimeSharingAdapter
    ) {
        self.virtualDisplay = virtualDisplay
        _controller = State(
            initialValue: HomeVirtualDisplaySurfaceController(
                capture: capture,
                sharing: sharing,
                virtualDisplay: virtualDisplay,
                capturePerformancePreferences: capturePerformancePreferences,
                displayRuntime: displayRuntime,
                sharingAdapter: sharingAdapter
            )
        )
    }

    package var body: some View {
        @Bindable var bindableController = controller
        @Bindable var bindableViewModel = controller.viewModel

        let presentation = controller.presentation
        let itemStates = controller.itemRenderStates(for: presentation.items)

        VStack(alignment: .leading, spacing: 0) {
            MenuBarQuickActionsHeader(
                summary: presentation.summary,
                openMainWindow: openMainWindow
            )
            .padding(.horizontal, AppUI.Spacing.large)
            .padding(.vertical, AppUI.Spacing.small)

            Divider()

            if itemStates.isEmpty {
                ContentUnavailableView(
                    "No Virtual Displays",
                    systemImage: "display.2",
                    description: Text("Create a virtual display in VoidDisplay to use quick actions here.")
                )
                .frame(maxWidth: .infinity, minHeight: 120)
                .accessibilityIdentifier("menu_bar_virtual_display_empty_state")
            } else if itemStates.count > Self.visibleRowLimit {
                ScrollView {
                    displayRows(itemStates)
                        .padding(.horizontal, AppUI.Spacing.large)
                }
                .frame(height: Self.scrollViewportHeight)
            } else {
                displayRows(itemStates)
                    .padding(.horizontal, AppUI.Spacing.large)
            }
        }
        .frame(width: Self.panelWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu_bar_quick_actions_panel")
        .alert(item: $bindableViewModel.userFacingAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    controller.viewModel.dismissAlert()
                }
            )
        }
        .alert(item: $bindableController.actionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    controller.dismissActionAlert()
                }
            )
        }
        .onAppear(perform: controller.handleAppear)
        .onDisappear(perform: controller.handleDisappear)
        .onChange(of: virtualDisplay.restoreFailures) { _, failures in
            controller.handleRestoreFailuresChanged(failures)
        }
        .onChange(of: controller.isCatalogLoading) { _, isLoading in
            controller.handleCatalogLoadingChanged(isLoading)
        }
        .onChange(of: controller.isWebServiceRunning) { _, isRunning in
            controller.handleSharingServiceStateChanged(isRunning: isRunning)
        }
        .onChange(of: controller.preferredSharingPort) { oldValue, newValue in
            controller.handlePreferredSharingPortChanged(from: oldValue, to: newValue)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            controller.handleCatalogTopologyChanged()
        }
    }

    private func openMainWindow() {
        openWindow(id: AppWindowID.main)
        navigation.showHome()
    }

    private func displayRows(
        _ itemStates: [HomeVirtualDisplayItemRenderState]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(itemStates) { state in
                MenuBarVirtualDisplayRow(
                    state: state,
                    performAction: { action in
                        perform(action, for: state.item)
                    }
                )

                if !state.isLast {
                    Divider()
                }
            }
        }
    }

    private func perform(
        _ action: MenuBarVirtualDisplayAction,
        for item: HomeVirtualDisplayItemPresentation
    ) {
        controller.performMenuBarAction(
            action,
            for: item,
            openPreviewWindow: { previewID in
                openWindow(value: previewID)
            }
        )
    }
}
