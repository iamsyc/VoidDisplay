import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SwiftUI
import VoidDisplayCapture
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

@MainActor
package struct HomeVirtualDisplaySurfaceView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    private let capture: CaptureController
    private let sharing: SharingController
    private let virtualDisplay: VirtualDisplayController
    private let capturePerformancePreferences: CapturePerformancePreferences
    private let displayRuntime: DisplayRuntime
    private let sharingAdapter: DisplayRuntimeSharingAdapter
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    @State private var viewModel: VirtualDisplayListViewModel
    @State private var createView = false
    @State private var editingConfig: EditingConfig?
    @State private var actionAlert: UserFacingAlertState?
    @State private var sharingPortInput = ""
    @State private var sharingPortErrorMessage: String?
    @State private var isConfigStoreDetailsExpanded = false
    @State private var displayDetectionState = HomeDisplayDetectionState()
    @State private var homeSurfaceWidth = CGFloat.infinity
    @State private var catalogSurfaceRegistration: DisplayRuntimeCatalogSurfaceRegistration?

    private struct EditingConfig: Identifiable {
        let id: UUID
    }

    package init(
        capture: CaptureController,
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        capturePerformancePreferences: CapturePerformancePreferences,
        displayRuntime: DisplayRuntime,
        sharingAdapter: DisplayRuntimeSharingAdapter,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void
    ) {
        self.capture = capture
        self.sharing = sharing
        self.virtualDisplay = virtualDisplay
        self.capturePerformancePreferences = capturePerformancePreferences
        self.displayRuntime = displayRuntime
        self.sharingAdapter = sharingAdapter
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
        _viewModel = State(initialValue: VirtualDisplayListViewModel(controller: virtualDisplay))
        _sharingPortInput = State(initialValue: String(sharing.preferredWebServicePort))
    }

    package var body: some View {
        @Bindable var bindableVirtualDisplay = virtualDisplay
        @Bindable var bindableViewModel = viewModel

        let presentation = HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: displayRuntime.makeSnapshot(),
            displayConfigs: virtualDisplay.displayConfigs,
            sharePageAddresses: sharePageAddresses
        )

        let metrics = HomeLayoutMetrics.current
        let itemStates = itemRenderStates(for: presentation.items)
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
                resetConfigStore: resetConfigStore
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
        .sheet(item: $editingConfig, content: editSheet)
        .confirmationDialog(
            "Delete Virtual Display",
            isPresented: $bindableViewModel.showDeleteConfirm,
            presenting: viewModel.deleteCandidate
        ) { config in
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelDelete()
            }
        } message: { config in
            Text("This will remove the configuration and disable the display if it is running.\n\n\(config.displayName) (Serial \(config.serialNum))")
        }
        .alert(item: $bindableViewModel.userFacingAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    viewModel.dismissAlert()
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
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    actionAlert = nil
                }
            )
        }
        .alert(String(localized: "Startup Failed"), isPresented: $bindableViewModel.showRestoreFailureAlert) {
            Button("OK") {
                viewModel.acknowledgeRestoreFailures()
            }
        } message: {
            Text(VirtualDisplayRowPresentation.restoreFailureSummary(virtualDisplay.restoreFailures))
        }
        .onAppear {
            viewModel.handleAppear()
            registerCatalogSurfaceIfNeeded()
        }
        .onDisappear {
            displayDetectionState.invalidate()
            unregisterCatalogSurfaceIfNeeded()
        }
        .task(id: catalogSurfaceRegistration) {
            guard let catalogSurfaceRegistration else { return }
            await refreshCatalogForHomeSurface(registration: catalogSurfaceRegistration)
        }
        .task(id: displayDetectionPresentation) {
            await clearTransientDisplayDetectionFeedback(
                presentation: displayDetectionPresentation
            )
        }
        .onChange(of: virtualDisplay.restoreFailures) { _, newValue in
            viewModel.handleRestoreFailuresChanged(newValue)
        }
        .onChange(of: displayRuntime.makeSnapshot().catalog.isLoadingDisplays) { _, isLoading in
            if isLoading {
                displayDetectionState.catalogRefreshDidStart()
            }
        }
        .onChange(of: sharing.isWebServiceRunning) { _, isRunning in
            Task {
                await displayRuntime.handleSharingServiceStateChanged(isRunning: isRunning)
            }
        }
        .onChange(of: sharing.preferredWebServicePort) { oldValue, newValue in
            if sharingPortInput == String(oldValue) || sharingPortErrorMessage == nil {
                sharingPortInput = String(newValue)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            Task {
                await displayRuntime.handleCatalogTopologyChanged()
            }
        }
    }

    private func editSheet(for item: EditingConfig) -> some View {
        EditVirtualDisplayConfigView(configId: item.id)
            .environment(virtualDisplay)
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
            permissionStatus: permissionStatus,
            displayDetection: displayDetectionPresentation,
            sharingSettings: sharingSettings,
            actions: HomeLayoutActions(
                createVirtualDisplay: {
                    createView = true
                },
                rescanDisplays: rescanDisplays,
                openScreenCapturePrivacySettings: {
                    openScreenCapturePrivacySettings { url in
                        openURL(url)
                    }
                },
                performItemAction: { action, item in
                    perform(action, for: item)
                },
                setCapturePerformanceMode: { mode in
                    capturePerformancePreferences.saveMode(mode)
                },
                updateSharingPortDraft: { newValue in
                    sharingPortInput = String(newValue.prefix(5))
                    sharingPortErrorMessage = nil
                },
                applySharingPortDraft: {
                    savePreferredSharingPort()
                }
            )
        )
    }

    private var permissionStatus: HomePermissionStatusRenderState {
        HomePermissionStatusRenderState(
            label: permissionLabel,
            systemImage: permissionSystemImage,
            tint: permissionTint,
            isActive: capture.displayCatalogState.hasScreenCapturePermission != nil,
            canOpenSettings: capture.displayCatalogState.hasScreenCapturePermission == false
        )
    }

    private var sharingSettings: HomeSharingSettingsRenderState {
        HomeSharingSettingsRenderState(
            performanceMode: capturePerformancePreferences.mode,
            portInput: sharingPortInput,
            isPortDirty: isSharingPortDirty,
            portErrorMessage: sharingPortErrorMessage,
            isWebServiceRunning: sharing.isWebServiceRunning,
            webServicePortValue: sharing.webServicePortValue
        )
    }

    private func itemRenderStates(
        for items: [HomeVirtualDisplayItemPresentation]
    ) -> [HomeVirtualDisplayItemRenderState] {
        items.map { item in
            HomeVirtualDisplayItemRenderState(
                item: item,
                isFirst: items.first?.id == item.id,
                isLast: items.last?.id == item.id,
                isToggling: viewModel.isToggling(configId: item.id),
                isRebuilding: virtualDisplay.isRebuilding(configId: item.id),
                hasRecentApplySuccess: virtualDisplay.hasRecentApplySuccess(configId: item.id),
                rebuildFailureMessage: virtualDisplay.rebuildFailureMessage(configId: item.id),
                isPrimary: viewModel.isPrimaryDisplay(configID: item.id),
                canSetAsPrimary: canSetAsPrimary(item),
                needsDisplayDetection: needsDisplayDetection(item),
                isDisplayDetectionScanning: displayDetectionPresentation.isScanning,
                isPreviewActionDisabled: isPreviewActionDisabled(item),
                isPreviewStarting: item.displayID.map(capture.isStarting(displayID:)) ?? false,
                isWebViewActionDisabled: isWebViewActionDisabled(item),
                isWebViewStarting: item.displayID.map(sharing.isStarting(displayID:)) ?? false
            )
        }
    }

    private func resetConfigStore() {
        do {
            _ = try virtualDisplay.resetVirtualDisplayData()
        } catch {}
    }

    private func perform(
        _ action: HomeVirtualDisplayItemAction,
        for item: HomeVirtualDisplayItemPresentation
    ) {
        switch action {
        case .toggle:
            guard let config = virtualDisplay.getConfig(item.id) else { return }
            viewModel.toggleDisplayState(config)
        case .preview:
            if item.isPreviewing {
                stopPreview(item)
            } else {
                startPreview(item)
            }
        case .webView:
            if item.isSharing {
                stopWebView(item)
            } else {
                startWebView(item)
            }
        case .openSharePage:
            openSharePage(item)
        case .copyShareAddress:
            copyShareAddress(item)
        case .edit:
            editingConfig = EditingConfig(id: item.id)
        case .moveUp:
            performPersistenceAction {
                _ = try virtualDisplay.moveDisplayConfig(item.id, direction: .up)
            }
        case .moveDown:
            performPersistenceAction {
                _ = try virtualDisplay.moveDisplayConfig(item.id, direction: .down)
            }
        case .setPrimary:
            performPersistenceAction {
                _ = try virtualDisplay.setPrimaryVirtualDisplayByReordering(item.id)
            }
        case .retryRebuild:
            virtualDisplay.retryRebuild(configId: item.id)
        case .delete:
            guard let config = virtualDisplay.getConfig(item.id) else { return }
            viewModel.requestDelete(config)
        }
    }

    private func startPreview(_ item: HomeVirtualDisplayItemPresentation) {
        guard let displayID = item.displayID else { return }
        Task {
            if let existingSession = previewActions.previewIDForDisplayID(displayID) {
                openWindow(value: existingSession)
                return
            }
            guard let display = await resolveDisplay(displayID: displayID) else {
                presentActionError(
                    title: String(localized: "Start Preview Failed"),
                    message: String(localized: "Display is not available for preview.")
                )
                return
            }
            do {
                let outcome = try await previewActions.startPreview(
                    display,
                    CapturePreviewDisplayMetadata(
                        displayName: displayName(for: display),
                        resolutionText: resolutionText(for: display),
                        isVirtualDisplay: true
                    )
                )
                if case .started(let previewID) = outcome {
                    openWindow(value: previewID)
                }
            } catch is CancellationError {
            } catch {
                presentActionError(
                    title: String(localized: "Start Preview Failed"),
                    message: AppErrorMapper.userMessage(
                        for: error,
                        fallback: String(localized: "Failed to start preview.")
                    )
                )
            }
        }
    }

    private func stopPreview(_ item: HomeVirtualDisplayItemPresentation) {
        guard let displayID = item.displayID else { return }
        Task {
            guard let previewID = previewActions.previewIDForDisplayID(displayID) else {
                return
            }
            await previewActions.closePreview(previewID)
        }
    }

    private func startWebView(_ item: HomeVirtualDisplayItemPresentation) {
        guard let displayID = item.displayID else { return }
        Task {
            guard await prepareWebViewSharing() else { return }
            guard let display = await resolveDisplay(displayID: displayID) else {
                presentActionError(
                    title: String(localized: "Share Failed"),
                    message: String(localized: "Display is not available for sharing.")
                )
                return
            }
            do {
                _ = try await sharingAdapter.beginLANWebViewSharing(
                    display: display,
                    runtime: displayRuntime
                )
            } catch is CancellationError {
            } catch {
                await sharingAdapter.stopLANWebViewSharing(
                    displayID: displayID,
                    runtime: displayRuntime
                )
                presentActionError(
                    title: String(localized: "Share Failed"),
                    message: AppErrorMapper.userMessage(
                        for: error,
                        fallback: String(localized: "Failed to start sharing.")
                    )
                )
            }
        }
    }

    private func stopWebView(_ item: HomeVirtualDisplayItemPresentation) {
        guard let displayID = item.displayID else { return }
        Task {
            await sharingAdapter.stopLANWebViewSharing(
                displayID: displayID,
                runtime: displayRuntime
            )
        }
    }

    private func openSharePage(_ item: HomeVirtualDisplayItemPresentation) {
        guard item.isSharing,
              let shareAddress = item.shareAddress,
              let shareURL = URL(string: shareAddress)
        else {
            return
        }
        openURL(shareURL)
    }

    private func copyShareAddress(_ item: HomeVirtualDisplayItemPresentation) {
        guard let shareAddress = item.shareAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareAddress, forType: .string)
    }

    private func prepareWebViewSharing() async -> Bool {
        if !sharing.isWebServiceRunning {
            guard let requestedPort = requestedSharingPortForStart() else {
                return false
            }
            let result = await sharing.startWebService(requestedPort: requestedPort)
            if case .failed(let failure) = result {
                presentActionError(
                    title: String(localized: "Share Failed"),
                    message: failure.userMessage
                )
                return false
            }
        }
        await displayRuntime.handleSharingServiceStateChanged(isRunning: sharing.isWebServiceRunning)
        return sharing.isWebServiceRunning
    }

    private func requestedSharingPortForStart() -> UInt16? {
        switch SharePortValidationError.parse(sharingPortInput) {
        case .success(let port):
            sharingPortInput = String(port)
            sharingPortErrorMessage = nil
            return port
        case .failure(let validationError):
            sharingPortErrorMessage = validationError.userMessage
            return nil
        }
    }

    private func savePreferredSharingPort() {
        switch SharePortValidationError.parse(sharingPortInput) {
        case .success(let port):
            sharing.savePreferredWebServicePort(port)
            sharingPortInput = String(port)
            sharingPortErrorMessage = nil
        case .failure(let validationError):
            sharingPortErrorMessage = validationError.userMessage
        }
    }

    private func registerCatalogSurfaceIfNeeded() {
        guard catalogSurfaceRegistration == nil else { return }
        catalogSurfaceRegistration = displayRuntime.registerCatalogSurface(source: .capturePage)
    }

    private func unregisterCatalogSurfaceIfNeeded() {
        guard let registration = catalogSurfaceRegistration else { return }
        catalogSurfaceRegistration = nil
        Task {
            await displayRuntime.unregisterCatalogSurface(registration)
        }
    }

    private func refreshCatalogForHomeSurface(
        registration: DisplayRuntimeCatalogSurfaceRegistration
    ) async {
        await displayRuntime.refreshCatalogSurface(registration)
        if sharing.isWebServiceRunning {
            await displayRuntime.handleSharingServiceStateChanged(isRunning: true)
        }
    }

    private func forceRefreshCatalogForHomeSurface() async -> DisplayRuntimeCatalogRefreshOutcome {
        await displayRuntime.forceRefreshCatalog(source: .capturePage)
    }

    private func rescanDisplays() {
        guard !displayDetectionState.isScanning else { return }
        let operationID = displayDetectionState.begin(
            previousCatalog: displayRuntime.makeSnapshot().catalog
        )

        Task {
            let refreshOutcome = await forceRefreshCatalogForHomeSurface()
            displayDetectionState.complete(
                operationID: operationID,
                refreshOutcome: refreshOutcome
            )
        }
    }

    private func clearTransientDisplayDetectionFeedback(
        presentation: HomeDisplayDetectionPresentation
    ) async {
        guard presentation.isTransient else { return }
        do {
            try await Task.sleep(for: .seconds(4))
        } catch {
            return
        }
        displayDetectionState.clearTransientOutcome(matching: presentation)
    }

    private func resolveDisplay(displayID: CGDirectDisplayID) async -> SCDisplay? {
        if let display = display(for: displayID) {
            return display
        }
        _ = await displayRuntime.forceRefreshCatalog(source: .capturePage)
        return display(for: displayID)
    }

    private func display(for displayID: CGDirectDisplayID) -> SCDisplay? {
        let displays =
            capture.displayCatalogState.activeShareableDisplays
            ?? sharing.displayCatalogState.activeShareableDisplays
            ?? []
        return displays.first { $0.displayID == displayID }
    }

    private func displayName(for display: SCDisplay) -> String {
        NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName ?? String(localized: "Display")
    }

    private func resolutionText(for display: SCDisplay) -> String {
        "\(display.width) × \(display.height)"
    }

    private func canSetAsPrimary(_ item: HomeVirtualDisplayItemPresentation) -> Bool {
        guard item.desiredEnabled,
              !viewModel.isToggling(configId: item.id),
              !virtualDisplay.isRebuilding(configId: item.id)
        else {
            return false
        }
        let firstEnabledID = virtualDisplay.displayConfigs.first(where: \.desiredEnabled)?.id
        return firstEnabledID != item.id
    }

    private func isPreviewActionDisabled(_ item: HomeVirtualDisplayItemPresentation) -> Bool {
        if displayRuntime.isConsumerTransitionBusy(
            surfaceIdentity: .managedVirtualDisplay(configID: item.id)
        ) {
            return true
        }
        guard let displayID = item.displayID else { return true }
        if capture.isStarting(displayID: displayID) { return true }
        if item.isPreviewing { return false }
        return display(for: displayID) == nil || capture.displayCatalogState.hasScreenCapturePermission == false
    }

    private func needsDisplayDetection(_ item: HomeVirtualDisplayItemPresentation) -> Bool {
        guard capture.displayCatalogState.hasScreenCapturePermission == true,
              capture.displayCatalogState.loadErrorMessage == nil,
              capture.displayCatalogState.lastLoadError == nil,
              item.isRunning,
              !item.isPreviewing,
              !item.isSharing,
              let displayID = item.displayID
        else {
            return false
        }
        return display(for: displayID) == nil
    }

    private func isWebViewActionDisabled(_ item: HomeVirtualDisplayItemPresentation) -> Bool {
        if displayRuntime.isConsumerTransitionBusy(
            surfaceIdentity: .managedVirtualDisplay(configID: item.id)
        ) {
            return true
        }
        guard let displayID = item.displayID else { return true }
        if sharing.isStarting(displayID: displayID) { return true }
        if item.isSharing { return false }
        return display(for: displayID) == nil || capture.displayCatalogState.hasScreenCapturePermission == false
    }

    private func performPersistenceAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {}
    }

    private func presentActionError(title: String, message: String) {
        actionAlert = UserFacingAlertState(title: title, message: message)
    }

    private var sharePageAddresses: [CGDirectDisplayID: String] {
        let catalogDisplayIDs = Set(
            (sharing.displayCatalogState.activeShareableDisplays ?? []).map(\.displayID)
        )
        let displayIDs = catalogDisplayIDs
            .union(sharing.activeSharingDisplayIDs)
            .union(sharing.startingDisplayIDs)
        return Dictionary(
            uniqueKeysWithValues: displayIDs.compactMap { displayID in
                sharing.sharePageAddress(for: displayID).map { (displayID, $0) }
            }
        )
    }

    private var previewActions: CapturePreviewActions {
        CaptureUIComposition.previewActions(
            capture: capture,
            displayRuntime: displayRuntime,
            capturePerformancePreferences: capturePerformancePreferences
        )
    }

    private var permissionLabel: String {
        switch capture.displayCatalogState.hasScreenCapturePermission {
        case true:
            String(localized: "Allowed")
        case false:
            String(localized: "Permission Needed")
        case nil:
            String(localized: "Checking")
        }
    }

    private var displayDetectionPresentation: HomeDisplayDetectionPresentation {
        let catalog = displayRuntime.makeSnapshot().catalog
        if displayDetectionState.isScanning || catalog.isLoadingDisplays {
            return .scanning
        }
        if catalog.hasLoadError {
            return .failed
        }
        return displayDetectionState.outcome
    }

    private var permissionSystemImage: String {
        switch capture.displayCatalogState.hasScreenCapturePermission {
        case true:
            "checkmark.shield"
        case false:
            "lock.shield"
        case nil:
            "arrow.triangle.2.circlepath"
        }
    }

    private var permissionTint: Color {
        switch capture.displayCatalogState.hasScreenCapturePermission {
        case true:
            .green
        case false:
            .orange
        case nil:
            .blue
        }
    }

    private var isSharingPortDirty: Bool {
        sharingPortInput.trimmingCharacters(in: .whitespacesAndNewlines) != String(sharing.preferredWebServicePort)
    }
}
