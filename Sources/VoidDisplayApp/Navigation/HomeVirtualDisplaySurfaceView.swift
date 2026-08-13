import AppKit
import Foundation
import SwiftUI
import VoidDisplayCapture
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

@MainActor
package struct HomeVirtualDisplaySurfaceView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    private let virtualDisplay: VirtualDisplayController
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void
    private let restoreSidebarFocus: @MainActor () -> Void

    @State private var controller: HomeVirtualDisplaySurfaceController
    @State private var createView = false
    @State private var editingConfigID: UUID?
    @State private var isConfigStoreDetailsExpanded = false
    @State private var homeSurfaceWidth = CGFloat.infinity

    package init(
        capture: CaptureController,
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        capturePerformancePreferences: CapturePerformancePreferences,
        displayRuntime: DisplayRuntime,
        sharingAdapter: DisplayRuntimeSharingAdapter,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void,
        restoreSidebarFocus: @escaping @MainActor () -> Void
    ) {
        self.virtualDisplay = virtualDisplay
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
        self.restoreSidebarFocus = restoreSidebarFocus
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
        @Bindable var bindableVirtualDisplay = virtualDisplay
        @Bindable var bindableViewModel = controller.viewModel

        let presentation = controller.presentation
        let metrics = HomeLayoutMetrics.current
        let itemStates = controller.itemRenderStates(for: presentation.items)
        let context = layoutContext(
            metrics: metrics,
            presentation: presentation,
            itemStates: itemStates
        )

        ScrollView {
            HomeVirtualDisplaySurfaceContent(
                context: context,
                configStorePresentation: virtualDisplay.configStorePresentation,
                isConfigStoreDetailsExpanded: $isConfigStoreDetailsExpanded,
                resetConfigStore: controller.resetConfigStore
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home_virtual_display_surface")
            .frame(maxWidth: metrics.contentMaxWidth, alignment: .topLeading)
            .appListContentInsets()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if context.displayDetection.showsStatus {
                HStack {
                    Spacer(minLength: 0)
                    HomeDisplayDetectionStatus(
                        presentation: context.displayDetection,
                        rescanDisplays: context.actions.rescanDisplays
                    )
                    .padding(.horizontal, AppUI.Spacing.medium)
                    .padding(.vertical, AppUI.Spacing.small)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.quaternary, lineWidth: AppUI.Stroke.subtle)
                    }
                }
                .padding(.horizontal, context.metrics.itemHorizontalPadding)
                .padding(.vertical, AppUI.Spacing.small)
            }
        }
        .accessibilityElement(children: .contain)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { newValue in
            homeSurfaceWidth = newValue
        }
        .sheet(isPresented: $createView) {
            CreateVirtualDisplay(isShow: $createView)
                .environment(virtualDisplay)
        }
        .sheet(isPresented: editingConfigIsPresented) {
            if let editingConfigID {
                EditVirtualDisplayConfigView(configId: editingConfigID)
                    .environment(virtualDisplay)
            }
        }
        .confirmationDialog(
            "Delete Virtual Display",
            isPresented: $bindableViewModel.showDeleteConfirm,
            presenting: controller.viewModel.deleteCandidate
        ) { config in
            Button("Delete", role: .destructive) {
                controller.viewModel.confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                controller.viewModel.cancelDelete()
            }
        } message: { config in
            Text("This will remove the configuration and disable the display if it is running.\n\n\(config.displayName) (Serial \(config.serialNum))")
        }
        .alert(item: $bindableViewModel.userFacingAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    controller.viewModel.dismissAlert()
                }
            )
        }
        .alert(item: $bindableVirtualDisplay.persistenceAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    virtualDisplay.dismissPersistenceAlert()
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
        .alert(String(localized: "Startup Failed"), isPresented: $bindableViewModel.showRestoreFailureAlert) {
            Button("OK") {
                controller.viewModel.acknowledgeRestoreFailures()
            }
        } message: {
            Text(VirtualDisplayRowPresentation.restoreFailureSummary(virtualDisplay.restoreFailures))
        }
        .onAppear {
            controller.handleAppear()
        }
        .onDisappear {
            controller.handleDisappear()
        }
        .onChange(of: virtualDisplay.restoreFailures) { _, newValue in
            controller.handleRestoreFailuresChanged(newValue)
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

    private var editingConfigIsPresented: Binding<Bool> {
        Binding(
            get: { editingConfigID != nil },
            set: { isPresented in
                if !isPresented {
                    editingConfigID = nil
                }
            }
        )
    }

    private func layoutContext(
        metrics: HomeLayoutMetrics,
        presentation: HomeVirtualDisplaySurfacePresentation,
        itemStates: [HomeVirtualDisplayItemRenderState]
    ) -> HomeLayoutContext {
        HomeLayoutContext(
            metrics: metrics,
            presentation: presentation,
            itemStates: itemStates,
            isCreateVirtualDisplayDisabled: virtualDisplay.configStorePresentation.hasLoadFailure,
            showsRescanToolbarTitle:
                homeSurfaceWidth >= metrics.minimumContentWidthForRescanToolbarTitle,
            permissionStatus: controller.permissionStatus,
            displayDetection: controller.displayDetectionPresentation,
            sharingSettings: controller.sharingSettings,
            actions: HomeLayoutActions(
                createVirtualDisplay: {
                    createView = true
                },
                rescanDisplays: controller.rescanDisplays,
                openScreenCapturePrivacySettings: {
                    openScreenCapturePrivacySettings { url in
                        openURL(url)
                    }
                },
                performItemAction: { action, item in
                    controller.perform(
                        action,
                        for: item,
                        openPreviewWindow: { previewID in
                            openWindow(value: previewID)
                        },
                        openSharePage: { shareURL in
                            openURL(shareURL)
                        },
                        editConfig: { configID in
                            editingConfigID = configID
                        }
                    )
                },
                setCapturePerformanceMode: controller.setCapturePerformanceMode,
                updateSharingPortDraft: controller.updateSharingPortDraft,
                applySharingPortDraft: controller.applySharingPortDraft,
                restoreSidebarFocus: restoreSidebarFocus
            )
        )
    }
}
