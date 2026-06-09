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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appSkinID) private var skinID
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    private let capture: CaptureController
    private let sharing: SharingController
    private let virtualDisplay: VirtualDisplayController
    private let capturePerformancePreferences: CapturePerformancePreferences
    private let displayRuntime: DisplayRuntime
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    @State private var viewModel: VirtualDisplayListViewModel
    @State private var createView = false
    @State private var editingConfig: EditingConfig?
    @State private var actionAlert: UserFacingAlertState?
    @State private var sharingPortInput = ""
    @State private var sharingPortErrorMessage: String?
    @State private var isConfigStoreDetailsExpanded = false

    private struct EditingConfig: Identifiable {
        let id: UUID
    }

    package init(
        capture: CaptureController,
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        capturePerformancePreferences: CapturePerformancePreferences,
        displayRuntime: DisplayRuntime,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void
    ) {
        self.capture = capture
        self.sharing = sharing
        self.virtualDisplay = virtualDisplay
        self.capturePerformancePreferences = capturePerformancePreferences
        self.displayRuntime = displayRuntime
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
            sharePageAddresses: SharingUIComposition.runtimeState(sharing: sharing).sharePageAddresses
        )

        let cardStates = cardRenderStates(for: presentation.cards)
        let theme = AppTheme.resolve(skinID: skinID, colorScheme: colorScheme)
        let context = skinContext(
            presentation: presentation,
            cardStates: cardStates,
            theme: theme
        )

        ScrollView {
            surfaceContent(context: context)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home_virtual_display_surface")
                .frame(maxWidth: theme.density.contentMaxWidth, alignment: .topLeading)
                .appListContentInsets()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
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
        }
        .onDisappear {
            viewModel.handleDisappear()
            Task {
                await displayRuntime.handleCatalogDisappear(source: .capturePage)
                await displayRuntime.handleCatalogDisappear(source: .sharingPage)
            }
        }
        .task {
            await refreshCatalogForHomeSurface()
        }
        .onChange(of: virtualDisplay.restoreFailures) { _, newValue in
            viewModel.handleRestoreFailuresChanged(newValue)
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
        .appSkin(skinID)
    }

    @ViewBuilder
    private func surfaceContent(context: HomeSkinContext) -> some View {
        HomeSkinRegistry.makeSkin(for: skinID, context: context) {
            cardContent(isEmpty: context.cardStates.isEmpty) {
                HomeSkinRegistry.makeCardContent(for: skinID, context: context)
            }
        }
    }

    @ViewBuilder
    private func cardContent<Content: View>(
        isEmpty: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if virtualDisplay.configStorePresentation.hasLoadFailure {
            configStoreErrorPanel
        } else if isEmpty {
            emptyState
        } else {
            content()
        }
    }

    private func editSheet(for item: EditingConfig) -> some View {
        EditVirtualDisplayConfigView(configId: item.id)
            .environment(virtualDisplay)
    }

    private func skinContext(
        presentation: HomeVirtualDisplaySurfacePresentation,
        cardStates: [HomeVirtualDisplayCardRenderState],
        theme: AppTheme
    ) -> HomeSkinContext {
        HomeSkinContext(
            presentation: presentation,
            cardStates: cardStates,
            theme: theme,
            isCreateVirtualDisplayDisabled: virtualDisplay.configStorePresentation.hasLoadFailure,
            permissionStatus: permissionStatus,
            sharingSettings: sharingSettings,
            actions: HomeSkinActions(
                createVirtualDisplay: {
                    createView = true
                },
                refresh: {
                    Task { await refreshCatalogForHomeSurface(force: true) }
                },
                openScreenCapturePrivacySettings: {
                    openScreenCapturePrivacySettings { url in
                        openURL(url)
                    }
                },
                performCardAction: { action, card in
                    perform(action, for: card)
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

    private func cardRenderStates(
        for cards: [HomeVirtualDisplayCardPresentation]
    ) -> [HomeVirtualDisplayCardRenderState] {
        cards.map { card in
            HomeVirtualDisplayCardRenderState(
                card: card,
                isFirst: cards.first?.id == card.id,
                isLast: cards.last?.id == card.id,
                isToggling: viewModel.isToggling(configId: card.id),
                isRebuilding: virtualDisplay.isRebuilding(configId: card.id),
                hasRecentApplySuccess: virtualDisplay.hasRecentApplySuccess(configId: card.id),
                rebuildFailureMessage: virtualDisplay.rebuildFailureMessage(configId: card.id),
                isPrimary: viewModel.isPrimaryDisplay(configID: card.id),
                canSetAsPrimary: canSetAsPrimary(card),
                isPreviewActionDisabled: isPreviewActionDisabled(card),
                isPreviewStarting: card.displayID.map(capture.isStarting(displayID:)) ?? false,
                isWebViewActionDisabled: isWebViewActionDisabled(card),
                isWebViewStarting: card.displayID.map(sharing.isStarting(displayID:)) ?? false
            )
        }
    }

    private var configStoreErrorPanel: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Label("Virtual Display Config File Unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(
                virtualDisplay.configStorePresentation.loadErrorMessage ??
                    String(localized: "The virtual display config file is incompatible or corrupted. Reset the config file to continue.")
            )
            .font(.body)

            if let diagnostics = virtualDisplay.configStorePresentation.diagnosticsSummary {
                DisclosureGroup(
                    isExpanded: $isConfigStoreDetailsExpanded,
                    content: {
                        Text(diagnostics)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    },
                    label: {
                        Text("Details")
                    }
                )
            }

            Button("Reset Config File", role: .destructive) {
                do {
                    _ = try virtualDisplay.resetVirtualDisplayData()
                } catch {}
            }
            .appActionButtonStyle(variant: .danger)
            .accessibilityIdentifier("virtual_display_reset_config_file_button")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: AppUI.Stroke.subtle)
        )
        .accessibilityIdentifier("virtual_display_config_store_error_panel")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Virtual Display",
            systemImage: "display.trianglebadge.exclamationmark",
            description: Text("Add a virtual display to start previewing or sharing it from Home.")
        )
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityIdentifier("virtual_displays_empty_state")
    }

    private func perform(
        _ action: HomeVirtualDisplayCardAction,
        for card: HomeVirtualDisplayCardPresentation
    ) {
        switch action {
        case .toggle:
            guard let config = virtualDisplay.getConfig(card.id) else { return }
            viewModel.toggleDisplayState(config)
        case .preview:
            if card.isPreviewing {
                stopPreview(card)
            } else {
                startPreview(card)
            }
        case .webView:
            if card.isSharing {
                stopWebView(card)
            } else {
                startWebView(card)
            }
        case .openSharePage:
            openSharePage(card)
        case .copyShareAddress:
            copyShareAddress(card)
        case .edit:
            editingConfig = EditingConfig(id: card.id)
        case .moveUp:
            performPersistenceAction {
                _ = try virtualDisplay.moveDisplayConfig(card.id, direction: .up)
            }
        case .moveDown:
            performPersistenceAction {
                _ = try virtualDisplay.moveDisplayConfig(card.id, direction: .down)
            }
        case .setPrimary:
            performPersistenceAction {
                _ = try virtualDisplay.setPrimaryVirtualDisplayByReordering(card.id)
            }
        case .retryRebuild:
            virtualDisplay.retryRebuild(configId: card.id)
        case .delete:
            guard let config = virtualDisplay.getConfig(card.id) else { return }
            viewModel.requestDelete(config)
        }
    }

    private func startPreview(_ card: HomeVirtualDisplayCardPresentation) {
        guard let displayID = card.displayID else { return }
        Task {
            if let existingSession = CaptureUIComposition
                .previewActions(capture: capture, displayRuntime: displayRuntime)
                .previewSessionForDisplayID(displayID) {
                openWindow(value: existingSession.id)
                return
            }
            guard let display = await resolveDisplay(displayID: displayID) else {
                presentActionError(
                    title: String(localized: "Start Preview Failed"),
                    message: String(localized: "Display is not available for preview.")
                )
                return
            }
            let actions = CaptureUIComposition.previewActions(
                capture: capture,
                displayRuntime: displayRuntime
            )
            do {
                let outcome = try await actions.startPreview(
                    display,
                    CapturePreviewDisplayMetadata(
                        displayName: displayName(for: display),
                        resolutionText: resolutionText(for: display),
                        isVirtualDisplay: true
                    )
                )
                if case .started(let sessionID) = outcome {
                    openWindow(value: sessionID)
                }
            } catch is CancellationError {
            } catch {
                AppErrorMapper.logFailure("Start preview", error: error, logger: AppLog.capture)
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

    private func stopPreview(_ card: HomeVirtualDisplayCardPresentation) {
        guard let displayID = card.displayID else { return }
        Task {
            guard let surfaceIdentity = displayRuntime.surfaceIdentityForDisplayID(displayID) else {
                return
            }
            _ = await displayRuntime.detachPreviewConsumer(surfaceIdentity: surfaceIdentity)
        }
    }

    private func startWebView(_ card: HomeVirtualDisplayCardPresentation) {
        guard let displayID = card.displayID else { return }
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
                _ = try await DisplayRuntimeSharingAdapter(controller: sharing)
                    .beginLANWebViewSharing(display: display, runtime: displayRuntime)
            } catch is CancellationError {
            } catch {
                await DisplayRuntimeSharingAdapter(controller: sharing)
                    .stopLANWebViewSharing(displayID: displayID, runtime: displayRuntime)
                AppErrorMapper.logFailure("Start sharing", error: error, logger: AppLog.sharing)
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

    private func stopWebView(_ card: HomeVirtualDisplayCardPresentation) {
        guard let displayID = card.displayID else { return }
        Task {
            await DisplayRuntimeSharingAdapter(controller: sharing)
                .stopLANWebViewSharing(displayID: displayID, runtime: displayRuntime)
        }
    }

    private func openSharePage(_ card: HomeVirtualDisplayCardPresentation) {
        guard card.isSharing,
              let shareAddress = card.shareAddress,
              let shareURL = URL(string: shareAddress)
        else {
            return
        }
        openURL(shareURL)
    }

    private func copyShareAddress(_ card: HomeVirtualDisplayCardPresentation) {
        guard let shareAddress = card.shareAddress else { return }
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

    private func refreshCatalogForHomeSurface(force: Bool = false) async {
        if force {
            await displayRuntime.forceRefreshCatalog(source: .capturePage)
        } else {
            await displayRuntime.handleCatalogAppear(source: .capturePage)
        }
        if sharing.isWebServiceRunning {
            await displayRuntime.handleSharingServiceStateChanged(isRunning: true)
        }
    }

    private func resolveDisplay(displayID: CGDirectDisplayID) async -> SCDisplay? {
        if let display = display(for: displayID) {
            return display
        }
        await displayRuntime.forceRefreshCatalog(source: .capturePage)
        return display(for: displayID)
    }

    private func display(for displayID: CGDirectDisplayID) -> SCDisplay? {
        let displays = capture.displayCatalogState.displays ?? sharing.displayCatalogState.displays ?? []
        return displays.first { $0.displayID == displayID }
    }

    private func displayName(for display: SCDisplay) -> String {
        NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName ?? String(localized: "Display")
    }

    private func resolutionText(for display: SCDisplay) -> String {
        "\(display.width) × \(display.height)"
    }

    private func canSetAsPrimary(_ card: HomeVirtualDisplayCardPresentation) -> Bool {
        guard card.desiredEnabled,
              !viewModel.isToggling(configId: card.id),
              !virtualDisplay.isRebuilding(configId: card.id)
        else {
            return false
        }
        let firstEnabledID = virtualDisplay.displayConfigs.first(where: \.desiredEnabled)?.id
        return firstEnabledID != card.id
    }

    private func isPreviewActionDisabled(_ card: HomeVirtualDisplayCardPresentation) -> Bool {
        guard let displayID = card.displayID else { return true }
        if capture.isStarting(displayID: displayID) { return true }
        if card.isPreviewing { return false }
        return display(for: displayID) == nil || capture.displayCatalogState.hasScreenCapturePermission == false
    }

    private func isWebViewActionDisabled(_ card: HomeVirtualDisplayCardPresentation) -> Bool {
        guard let displayID = card.displayID else { return true }
        if sharing.isStarting(displayID: displayID) { return true }
        if card.isSharing { return false }
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
