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

        ScrollView {
            VStack(alignment: .leading, spacing: AppUI.Spacing.large) {
                header
                summaryPanel(presentation.summary)

                if virtualDisplay.configStorePresentation.hasLoadFailure {
                    configStoreErrorPanel
                } else if presentation.cards.isEmpty {
                    emptyState
                } else {
                    cardGrid(presentation.cards)
                }
            }
            .frame(maxWidth: HomeLayout.contentMaxWidth, alignment: .topLeading)
            .appListContentInsets()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home_virtual_display_surface")
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
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                titleBlock
                Spacer(minLength: AppUI.Spacing.large)
                headerActions
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                titleBlock
                headerActions
            }
        }
    }

    private func editSheet(for item: EditingConfig) -> some View {
        EditVirtualDisplayConfigView(configId: item.id)
            .environment(virtualDisplay)
    }

    private var titleBlock: some View {
        Label("Virtual Displays", systemImage: "display.2")
            .font(.title2.weight(.semibold))
            .accessibilityIdentifier("home_virtual_display_surface")
    }

    private var headerActions: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Button {
                createView = true
            } label: {
                Label("Add Virtual Display", systemImage: "plus")
                    .accessibilityIdentifier("home_add_virtual_display_button")
            }
            .appActionButtonStyle(variant: .primary)
            .disabled(virtualDisplay.configStorePresentation.hasLoadFailure)
            .accessibilityIdentifier("home_add_virtual_display_button")

            Button {
                Task { await refreshCatalogForHomeSurface(force: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .appActionButtonStyle(variant: .default)
            .accessibilityIdentifier("home_refresh_button")
        }
        .labelStyle(.titleAndIcon)
    }

    private func summaryPanel(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small + 2) {
            summaryStatusLayout(summary)

            Divider()
                .padding(.vertical, 1)

            sharingSettingsPanel
        }
        .padding(.horizontal, AppUI.Spacing.large)
        .padding(.vertical, AppUI.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppUI.Surface.cardFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppUI.Surface.cardStroke(for: colorScheme), lineWidth: AppUI.Stroke.subtle)
        )
        .accessibilityLabel(Text("Current Status"))
        .accessibilityIdentifier("home_summary_panel")
    }

    private func summaryStatusLayout(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        summaryStatusStrip(summary)
    }

    private func summaryVirtualDisplayMetric(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        HomeSummaryStatusItem(
            title: String(localized: "Virtual Displays"),
            value: "\(summary.virtualDisplayCount)",
            systemImage: "display.2",
            tint: .blue,
            isActive: true,
            usesProminentValue: true
        )
    }

    private func summaryRunningMetric(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        HomeSummaryStatusItem(
            title: String(localized: "Running"),
            value: "\(summary.runningVirtualDisplayCount)",
            systemImage: "checkmark.rectangle.stack",
            tint: summary.runningVirtualDisplayCount > 0 ? .green : .secondary,
            isActive: summary.runningVirtualDisplayCount > 0,
            usesProminentValue: true
        )
    }

    @ViewBuilder
    private var permissionAction: some View {
        if capture.displayCatalogState.hasScreenCapturePermission == false {
            Button {
                openScreenCapturePrivacySettings { url in
                    openURL(url)
                }
            } label: {
                Label("Open Privacy Settings", systemImage: "lock.shield")
            }
            .appActionButtonStyle(variant: .default)
            .accessibilityIdentifier("home_open_privacy_settings_button")
        }
    }

    private func summaryStatusStrip(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                summaryVirtualDisplayMetric(summary)
                summaryStatusDivider
                summaryRunningMetric(summary)
                summaryStatusDivider
                summaryPreviewStatus(summary)
                summaryStatusDivider
                summaryWebViewStatus(summary)
                summaryStatusDivider
                summaryViewersStatus(summary)
                Spacer(minLength: AppUI.Spacing.small)
                summaryPermissionStatus
                permissionAction
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                summaryPrimaryStatusRow(summary)
                summaryActivityStatusRow(summary)
            }
        }
        .padding(.horizontal, AppUI.Spacing.small)
        .padding(.vertical, AppUI.Spacing.xSmall + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colorScheme == .dark ? .white.opacity(0.035) : .black.opacity(0.018))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(colorScheme == .dark ? .white.opacity(0.07) : .black.opacity(0.045), lineWidth: AppUI.Stroke.subtle)
        )
        .accessibilityIdentifier("home_summary_status_strip")
    }

    private func summaryPrimaryStatusRow(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                summaryVirtualDisplayMetric(summary)
                summaryStatusDivider
                summaryRunningMetric(summary)
                Spacer(minLength: AppUI.Spacing.small)
                summaryPermissionStatus
                permissionAction
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    summaryVirtualDisplayMetric(summary)
                    summaryStatusDivider
                    summaryRunningMetric(summary)
                }
                HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                    summaryPermissionStatus
                    permissionAction
                }
            }
        }
    }

    private func summaryActivityStatusRow(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 0) {
                summaryPreviewStatus(summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                summaryStatusDivider
                summaryWebViewStatus(summary)
                    .frame(maxWidth: .infinity, alignment: .center)
                summaryStatusDivider
                summaryViewersStatus(summary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall) {
                summaryPreviewStatus(summary)
                summaryWebViewStatus(summary)
                summaryViewersStatus(summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryPreviewStatus(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        HomeSummaryStatusItem(
            title: String(localized: "Preview"),
            value: "\(summary.previewingCount)",
            systemImage: "dot.scope.display",
            tint: summary.previewingCount > 0 ? .green : .secondary,
            isActive: summary.previewingCount > 0
        )
    }

    private func summaryWebViewStatus(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        HomeSummaryStatusItem(
            title: String(localized: "Web View"),
            value: "\(summary.sharingCount)",
            systemImage: "network",
            tint: summary.sharingCount > 0 ? .green : .secondary,
            isActive: summary.sharingCount > 0
        )
    }

    private func summaryViewersStatus(_ summary: HomeRuntimeSummaryPresentation) -> some View {
        HomeSummaryStatusItem(
            title: String(localized: "Viewers"),
            value: "\(summary.activeViewerCount)",
            systemImage: "person.2",
            tint: summary.activeViewerCount > 0 ? .blue : .secondary,
            isActive: summary.activeViewerCount > 0
        )
    }

    private var summaryPermissionStatus: some View {
        HomeSummaryStatusItem(
            title: String(localized: "Screen Recording"),
            value: permissionLabel,
            systemImage: permissionSystemImage,
            tint: permissionTint,
            isActive: capture.displayCatalogState.hasScreenCapturePermission != nil
        )
    }

    private var summaryStatusDivider: some View {
        Divider()
            .frame(height: 16)
    }

    private var sharingSettingsPanel: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                sharingSettingsTitle
                    .frame(minWidth: 112, alignment: .leading)

                sharingSettingsDivider
                sharingSettingsControlsInline

                Spacer(minLength: AppUI.Spacing.small)
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                sharingSettingsTitle
                sharingSettingsControlsResponsive
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("home_sharing_settings_panel")
    }

    private var sharingSettingsControlsResponsive: some View {
        ViewThatFits(in: .horizontal) {
            sharingSettingsControlsInline

            sharingSettingsControlsStack
        }
    }

    private var sharingSettingsControlsInline: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            sharingPerformanceControl
            sharingSettingsDivider
            sharingPortControl
        }
    }

    private var sharingSettingsDivider: some View {
        Divider()
            .frame(height: 24)
    }

    private var sharingSettingsControlsStack: some View {
        Grid(alignment: .leading, horizontalSpacing: AppUI.Spacing.small, verticalSpacing: AppUI.Spacing.small) {
            GridRow {
                sharingSettingsControlLabel("Performance")
                sharingPerformancePicker
            }

            GridRow {
                sharingSettingsControlLabel("Port")
                VStack(alignment: .leading, spacing: 4) {
                    sharingPortValueControls
                    sharingPortErrorText
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sharingSettingsTitle: some View {
        Label("Screen Sharing", systemImage: "network")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private var sharingPerformanceControl: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            sharingSettingsControlLabel("Performance")
            sharingPerformancePicker
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sharingPortControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                sharingSettingsControlLabel("Port")
                sharingPortValueControls
            }

            sharingPortErrorText
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sharingSettingsControlLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var sharingPerformancePicker: some View {
        Picker("Capture Performance", selection: capturePerformanceModeBinding) {
            Text("Automatic").tag(CapturePerformanceMode.automatic)
            Text("Smooth").tag(CapturePerformanceMode.smooth)
            Text("Power Efficient").tag(CapturePerformanceMode.powerEfficient)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .tint(.gray)
        .frame(width: 224, alignment: .leading)
        .accessibilityIdentifier("home_sharing_performance_picker")
    }

    private var sharingPortValueControls: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            TextField("8089", text: sharingPortInputBinding)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .onSubmit {
                    savePreferredSharingPort()
                }
                .accessibilityIdentifier("home_sharing_port_input")

            if isSharingPortDirty {
                Button {
                    savePreferredSharingPort()
                } label: {
                    Image(systemName: "checkmark")
                }
                .appActionButtonStyle(variant: .default)
                .controlSize(.small)
                .frame(width: 30)
                .help(Text("Apply"))
                .accessibilityLabel(Text("Apply"))
                .accessibilityIdentifier("home_sharing_port_apply_button")
            }

            if sharing.isWebServiceRunning {
                HomeSharingPortStatusBadge(port: sharing.webServicePortValue)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var sharingPortErrorText: some View {
        if let sharingPortErrorMessage {
            Text(sharingPortErrorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 14, alignment: .leading)
                .accessibilityIdentifier("home_sharing_port_error_text")
        }
    }

    private func cardGrid(_ cards: [HomeVirtualDisplayCardPresentation]) -> some View {
        LazyVStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            ForEach(cards) { card in
                HomeVirtualDisplayCard(
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
                    isWebViewStarting: card.displayID.map(sharing.isStarting(displayID:)) ?? false,
                    perform: { action in
                        perform(action, for: card)
                    }
                )
                .accessibilityIdentifier("home_virtual_display_card")
            }
        }
        .accessibilityIdentifier("home_virtual_display_card_grid")
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
                    message: String(localized: "Display is not available for Web View.")
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

    private var capturePerformanceModeBinding: Binding<CapturePerformanceMode> {
        Binding(
            get: { capturePerformancePreferences.mode },
            set: { capturePerformancePreferences.saveMode($0) }
        )
    }

    private var sharingPortInputBinding: Binding<String> {
        Binding(
            get: { sharingPortInput },
            set: { newValue in
                sharingPortInput = String(newValue.prefix(5))
                sharingPortErrorMessage = nil
            }
        )
    }

    private var isSharingPortDirty: Bool {
        sharingPortInput.trimmingCharacters(in: .whitespacesAndNewlines) != String(sharing.preferredWebServicePort)
    }
}

private enum HomeVirtualDisplayCardAction {
    case toggle
    case preview
    case webView
    case edit
    case moveUp
    case moveDown
    case setPrimary
    case retryRebuild
    case delete
}

private enum HomeLayout {
    static let contentMaxWidth: CGFloat = 1240
    static let cardIdentityWidth: CGFloat = 330
    static let cardStatusWidth: CGFloat = 300
    static let cardActionWidth: CGFloat = 420
}

private struct HomeVirtualDisplayCard: View {
    let card: HomeVirtualDisplayCardPresentation
    let isFirst: Bool
    let isLast: Bool
    let isToggling: Bool
    let isRebuilding: Bool
    let hasRecentApplySuccess: Bool
    let rebuildFailureMessage: String?
    let isPrimary: Bool
    let canSetAsPrimary: Bool
    let isPreviewActionDisabled: Bool
    let isPreviewStarting: Bool
    let isWebViewActionDisabled: Bool
    let isWebViewStarting: Bool
    let perform: (HomeVirtualDisplayCardAction) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    private var isBusy: Bool {
        isToggling || isRebuilding
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            compactLayout
            narrowLayout
        }
        .padding(AppUI.Spacing.large)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppUI.Surface.cardFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardStroke, lineWidth: AppUI.Stroke.subtle)
        )
        .onHover { hovered in
            isHovered = hovered
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(card.accessibilitySummary))
    }

    private var wideLayout: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            identityBlock
                .layoutPriority(2)
                .frame(width: HomeLayout.cardIdentityWidth, alignment: .leading)

            if hasOperationalStatusItems {
                statusGrid
                    .layoutPriority(1)
                    .frame(width: HomeLayout.cardStatusWidth, alignment: .leading)
            } else {
                Spacer(minLength: AppUI.Spacing.medium)
            }

            actionStack
                .frame(width: HomeLayout.cardActionWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                identityBlock
                    .layoutPriority(1)

                Spacer(minLength: AppUI.Spacing.medium)

                toggleButton
            }

            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                if hasOperationalStatusItems {
                    statusGrid
                }

                Spacer(minLength: AppUI.Spacing.medium)

                compactActionCluster
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
    }

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                identityBlock
                    .layoutPriority(1)

                Spacer(minLength: AppUI.Spacing.medium)

                toggleButton
            }

            if hasOperationalStatusItems {
                statusGrid
            }

            compactActionCluster
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var identityBlock: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            Image(systemName: "display")
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary.opacity(0.88), iconTint)
                .frame(width: 46, height: 46)
                .appTileStyle()

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall) {
                Text(card.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(card.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                statusBadgeRow
            }
        }
    }

    private var statusGrid: some View {
        HStack(spacing: AppUI.Spacing.small + 2) {
            ForEach(card.operationalStatusItems) { item in
                HomeInlineStatusPill(item: item)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("home_card_status_grid")
    }

    private var actionStack: some View {
        VStack(alignment: .trailing, spacing: AppUI.Spacing.small) {
            toggleButton
            secondaryActionCluster
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var compactActionCluster: some View {
        HStack(spacing: AppUI.Spacing.xSmall + 2) {
            compactPreviewButton
            compactWebViewButton
            compactCopyShareAddressButton
            compactEditButton
            moreMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var secondaryActionCluster: some View {
        HStack(spacing: AppUI.Spacing.xSmall + 2) {
            previewButton
            webViewButton
            copyShareAddressButton
            editButton
            moreMenu
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private var primaryStatusBadge: some View {
        if let rebuildFailureMessage {
            HomeStatusBadge(
                title: card.statusLabel,
                tone: card.statusTone
            )
            .help(rebuildFailureMessage)
        } else {
            HomeStatusBadge(
                title: card.statusLabel,
                tone: card.statusTone
            )
        }
    }

    @ViewBuilder
    private var statusBadgeRow: some View {
        HStack(spacing: 6) {
            primaryStatusBadge

            if isPrimary {
                HomeStatusBadge(
                    title: String(localized: "Primary Display"),
                    tone: .success
                )
                .accessibilityIdentifier("virtual_display_primary_ribbon")
            }

            if hasRecentApplySuccess {
                HomeStatusBadge(
                    title: String(localized: "Applied"),
                    tone: .success
                )
            }
        }
    }

    private var hasOperationalStatusItems: Bool {
        !card.operationalStatusItems.isEmpty
    }

    private var toggleButton: some View {
        Button {
            perform(.toggle)
        } label: {
            if isToggling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(
                    card.isRunning ? String(localized: "Disable") : String(localized: "Enable"),
                    systemImage: card.isRunning ? "pause.fill" : "play.fill"
                )
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(card.isRunning ? .orange : .green)
        .disabled(isBusy)
        .controlSize(.regular)
        .frame(minWidth: 94)
        .accessibilityIdentifier("virtual_display_toggle_button")
    }

    private var previewButton: some View {
        Button {
            perform(.preview)
        } label: {
            if isPreviewStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(
                    card.isPreviewing ? String(localized: "Stop Preview") : String(localized: "Preview"),
                    systemImage: card.isPreviewing ? "stop.fill" : "dot.scope.display"
                )
            }
        }
        .appActionButtonStyle(variant: .default)
        .disabled(isPreviewActionDisabled)
        .controlSize(.small)
        .frame(minWidth: 78)
        .accessibilityIdentifier("home_virtual_display_preview_button")
    }

    private var compactPreviewButton: some View {
        Button {
            perform(.preview)
        } label: {
            if isPreviewStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: card.isPreviewing ? "stop.fill" : "dot.scope.display")
            }
        }
        .appActionButtonStyle(variant: .default)
        .disabled(isPreviewActionDisabled)
        .controlSize(.small)
        .frame(minWidth: 32)
        .help(Text(card.isPreviewing ? String(localized: "Stop Preview") : String(localized: "Preview")))
        .accessibilityLabel(Text(card.isPreviewing ? String(localized: "Stop Preview") : String(localized: "Preview")))
        .accessibilityIdentifier("home_virtual_display_preview_button")
    }

    private var webViewButton: some View {
        Button {
            perform(.webView)
        } label: {
            if isWebViewStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(
                    card.isSharing ? String(localized: "Stop Web View") : String(localized: "Web View"),
                    systemImage: card.isSharing ? "stop.fill" : "network"
                )
            }
        }
        .appActionButtonStyle(variant: .default)
        .disabled(isWebViewActionDisabled)
        .controlSize(.small)
        .frame(minWidth: 92)
        .accessibilityIdentifier("home_virtual_display_web_view_button")
    }

    private var compactWebViewButton: some View {
        Button {
            perform(.webView)
        } label: {
            if isWebViewStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: card.isSharing ? "stop.fill" : "network")
            }
        }
        .appActionButtonStyle(variant: .default)
        .disabled(isWebViewActionDisabled)
        .controlSize(.small)
        .frame(minWidth: 32)
        .help(Text(card.isSharing ? String(localized: "Stop Web View") : String(localized: "Web View")))
        .accessibilityLabel(Text(card.isSharing ? String(localized: "Stop Web View") : String(localized: "Web View")))
        .accessibilityIdentifier("home_virtual_display_web_view_button")
    }

    @ViewBuilder
    private var copyShareAddressButton: some View {
        if let shareAddress {
            Button {
                copyShareAddress()
            } label: {
                Label(String(localized: "Copy Link"), systemImage: "doc.on.doc")
            }
            .appActionButtonStyle(variant: .default)
            .controlSize(.small)
            .frame(minWidth: 82)
            .help(shareAddress)
            .accessibilityValue(Text(verbatim: shareAddress))
            .accessibilityIdentifier("home_virtual_display_copy_share_address_button")
        }
    }

    @ViewBuilder
    private var compactCopyShareAddressButton: some View {
        if let shareAddress {
            Button {
                copyShareAddress()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .appActionButtonStyle(variant: .default)
            .controlSize(.small)
            .frame(minWidth: 32)
            .help(shareAddress)
            .accessibilityLabel(Text("Copy Link"))
            .accessibilityValue(Text(verbatim: shareAddress))
            .accessibilityIdentifier("home_virtual_display_copy_share_address_button")
        }
    }

    private func openSharePage() {
        guard card.isSharing, let shareURL else { return }
        openURL(shareURL)
    }

    private func copyShareAddress() {
        guard let shareAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareAddress, forType: .string)
    }

    private var shareAddress: String? {
        card.shareAddress
    }

    private var shareURL: URL? {
        shareAddress.flatMap(URL.init(string:))
    }

    private var editButton: some View {
        Button {
            perform(.edit)
        } label: {
            Label("Edit", systemImage: "square.and.pencil")
        }
        .appActionButtonStyle(variant: .default)
        .disabled(isBusy)
        .controlSize(.small)
        .frame(minWidth: 68)
        .accessibilityIdentifier("virtual_display_edit_button")
    }

    private var compactEditButton: some View {
        Button {
            perform(.edit)
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .appActionButtonStyle(variant: .default)
        .disabled(isBusy)
        .controlSize(.small)
        .frame(minWidth: 32)
        .help(Text("Edit"))
        .accessibilityLabel(Text("Edit"))
        .accessibilityIdentifier("virtual_display_edit_button")
    }

    private var moreMenu: some View {
        Menu {
            if shareAddress != nil {
                Button("Open Share Page", systemImage: "link") {
                    openSharePage()
                }
                .disabled(!card.isSharing || shareURL == nil)

                Button("Copy display address", systemImage: "doc.on.doc") {
                    copyShareAddress()
                }

                Divider()
            }

            Button("Set as Primary", systemImage: isPrimary ? "star.circle.fill" : "star.circle") {
                perform(.setPrimary)
            }
            .disabled(!canSetAsPrimary)

            Divider()

            Button("Move up", systemImage: "chevron.up") {
                perform(.moveUp)
            }
            .disabled(isFirst || isBusy)

            Button("Move down", systemImage: "chevron.down") {
                perform(.moveDown)
            }
            .disabled(isLast || isBusy)

            if rebuildFailureMessage != nil {
                Divider()
                Button("Retry Rebuild", systemImage: "arrow.clockwise") {
                    perform(.retryRebuild)
                }
                .disabled(isBusy)
            }

            Divider()

            Button("Delete", systemImage: "trash", role: .destructive) {
                perform(.delete)
            }
            .disabled(isBusy)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .help(Text("More"))
        .accessibilityLabel(Text("More"))
        .accessibilityIdentifier("home_virtual_display_more_button")
    }

    private var iconTint: Color {
        DisplayIconTintResolver.resolve(
            isPreviewing: card.isPreviewing,
            isSharing: card.isSharing
        ) ?? (card.isRunning ? DisplayIconTintResolver.enabledIdle : .secondary)
    }

    private var cardStroke: Color {
        if card.hasIssue || rebuildFailureMessage != nil {
            return .orange.opacity(colorScheme == .dark ? 0.52 : 0.36)
        }
        if isHovered {
            return AppUI.Surface.cardHoverStroke(for: colorScheme)
        }
        return AppUI.Surface.cardStroke(for: colorScheme)
    }
}

private struct HomeSummaryMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(minWidth: 96, alignment: .leading)
    }
}

private struct HomeSummaryStatusItem: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    let isActive: Bool
    let usesProminentValue: Bool

    init(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        isActive: Bool,
        usesProminentValue: Bool = false
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.isActive = isActive
        self.usesProminentValue = usesProminentValue
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 14)

            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(valueForegroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title): \(value)"))
    }

    private var valueForegroundColor: Color {
        if usesProminentValue {
            return .primary
        }
        return isActive ? tint : .secondary
    }
}

private struct HomeSharingPortStatusBadge: View {
    let port: UInt16

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text(verbatim: "\(String(localized: "Active Port")) \(String(port))")
                .foregroundStyle(.secondary)
        }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help(Text("Active Port"))
            .accessibilityIdentifier("home_sharing_active_port_badge")
    }
}

private struct HomeStatusBadge: View {
    let title: String
    let tone: DisplaySurfaceStatusTone

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, AppUI.Spacing.small - 1)
            .padding(.vertical, AppUI.Spacing.xSmall)
            .background(tone.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(tone.tint)
    }
}

private struct HomeInlineStatusPill: View {
    let item: DisplaySurfaceStatusItemPresentation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isLowPriority = item.tone == .neutral
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isLowPriority ? .secondary : item.tone.tint)
                .frame(width: 13)

            Text(item.value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isLowPriority ? .secondary : item.tone.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption)
        .padding(.horizontal, AppUI.Spacing.small)
        .padding(.vertical, AppUI.Spacing.xSmall + 1)
        .background(
            statusFill(isLowPriority: isLowPriority),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(statusStroke(isLowPriority: isLowPriority), lineWidth: AppUI.Stroke.subtle)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(item.title): \(item.value)"))
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }

    private var systemImage: String {
        switch item.id {
        case "preview":
            "dot.scope.display"
        case "webView":
            "network"
        case "viewerCount":
            "person.2"
        case "issue":
            "exclamationmark.triangle"
        default:
            "circle"
        }
    }

    private func statusFill(isLowPriority: Bool) -> Color {
        if isLowPriority {
            return colorScheme == .dark ? .white.opacity(0.035) : .black.opacity(0.024)
        }
        return item.tone.tint.opacity(colorScheme == .dark ? 0.18 : 0.10)
    }

    private func statusStroke(isLowPriority: Bool) -> Color {
        if isLowPriority {
            return colorScheme == .dark ? .white.opacity(0.055) : .black.opacity(0.045)
        }
        return item.tone.tint.opacity(colorScheme == .dark ? 0.28 : 0.20)
    }
}

private extension DisplaySurfaceStatusTone {
    var tint: Color {
        switch self {
        case .neutral:
            .gray
        case .info:
            .blue
        case .success:
            .green
        case .warning:
            .orange
        case .danger:
            .red
        }
    }
}
