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
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    @State private var viewModel: VirtualDisplayListViewModel
    @State private var createView = false
    @State private var editingConfig: EditingConfig?
    @State private var actionAlert: UserFacingAlertState?
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
    }

    package var body: some View {
        @Bindable var bindableVirtualDisplay = virtualDisplay
        @Bindable var bindableViewModel = viewModel

        let presentation = HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: displayRuntime.makeSnapshot(),
            displayConfigs: virtualDisplay.displayConfigs
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
        VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
            Label("Virtual Displays", systemImage: "display.2")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("home_virtual_display_surface")
            Text("Manage virtual displays, preview, and Web View from one place.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    Label("Current Status", systemImage: summary.recentFailureCount > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.headline)
                        .foregroundStyle(summary.recentFailureCount > 0 ? .orange : .primary)
                    Spacer(minLength: AppUI.Spacing.large)
                    permissionAction
                }

                VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                    Label("Current Status", systemImage: summary.recentFailureCount > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.headline)
                        .foregroundStyle(summary.recentFailureCount > 0 ? .orange : .primary)
                    permissionAction
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 136), spacing: AppUI.Spacing.small, alignment: .top)],
                alignment: .leading,
                spacing: AppUI.Spacing.small
            ) {
                HomeSummaryTile(
                    title: String(localized: "Virtual Displays"),
                    value: "\(summary.virtualDisplayCount)",
                    systemImage: "display.2",
                    tint: .blue
                )
                HomeSummaryTile(
                    title: String(localized: "Running"),
                    value: "\(summary.runningVirtualDisplayCount)",
                    systemImage: "checkmark.rectangle.stack",
                    tint: summary.runningVirtualDisplayCount > 0 ? .green : .secondary
                )
                HomeSummaryTile(
                    title: String(localized: "Preview"),
                    value: "\(summary.previewingCount)",
                    systemImage: "dot.scope.display",
                    tint: summary.previewingCount > 0 ? .green : .secondary
                )
                HomeSummaryTile(
                    title: String(localized: "Web View"),
                    value: "\(summary.sharingCount)",
                    systemImage: "network",
                    tint: summary.sharingCount > 0 ? .green : .secondary
                )
                HomeSummaryTile(
                    title: String(localized: "Viewers"),
                    value: "\(summary.activeViewerCount)",
                    systemImage: "person.2",
                    tint: summary.activeViewerCount > 0 ? .blue : .secondary
                )
                HomeSummaryTile(
                    title: String(localized: "Recent Failures"),
                    value: "\(summary.recentFailureCount)",
                    systemImage: summary.recentFailureCount == 0 ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: summary.recentFailureCount == 0 ? .green : .orange
                )
                HomeSummaryTile(
                    title: String(localized: "Screen Recording"),
                    value: permissionLabel,
                    systemImage: permissionSystemImage,
                    tint: permissionTint
                )
                HomeSummaryTile(
                    title: String(localized: "Performance"),
                    value: performanceLabel,
                    systemImage: "speedometer",
                    tint: .purple
                )
            }

            if let lastFailureCode = summary.lastFailureCode {
                HStack(alignment: .firstTextBaseline, spacing: AppUI.Spacing.small) {
                    Text("Diagnostic Code")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(lastFailureCode)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("home_last_failure_code")
            }
        }
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier("home_summary_panel")
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

    private func cardGrid(_ cards: [HomeVirtualDisplayCardPresentation]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 360), spacing: AppUI.Spacing.medium, alignment: .top)],
            alignment: .leading,
            spacing: AppUI.Spacing.medium
        ) {
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
            let result = await sharing.startWebService(requestedPort: sharing.preferredWebServicePort)
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

    private var performanceLabel: String {
        switch capturePerformancePreferences.mode {
        case .automatic:
            String(localized: "Automatic")
        case .smooth:
            String(localized: "Smooth")
        case .powerEfficient:
            String(localized: "Power Efficient")
        }
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
    @State private var isHovered = false

    private var isBusy: Bool {
        isToggling || isRebuilding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            identityHeader
            statusGrid
            actionBar
        }
        .frame(maxWidth: .infinity, minHeight: 214, alignment: .topLeading)
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

    private var identityHeader: some View {
        HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
            Image(systemName: "display")
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary.opacity(0.88), iconTint)
                .frame(width: 48, height: 48)
                .appTileStyle()

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall) {
                HStack(spacing: AppUI.Spacing.xSmall + 2) {
                    Text(card.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isPrimary {
                        HomeStatusBadge(
                            title: String(localized: "Primary Display"),
                            tone: .success
                        )
                        .accessibilityIdentifier("virtual_display_primary_ribbon")
                    }
                }

                Text(card.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    HomeStatusBadge(
                        title: card.statusLabel,
                        tone: card.statusTone
                    )
                    if hasRecentApplySuccess {
                        HomeStatusBadge(
                            title: String(localized: "Applied"),
                            tone: .success
                        )
                    }
                    if let rebuildFailureMessage {
                        HomeStatusBadge(
                            title: String(localized: "Needs attention"),
                            tone: .danger
                        )
                        .help(rebuildFailureMessage)
                    }
                }
            }

            Spacer(minLength: 0)

            moreMenu
        }
    }

    private var statusGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 112), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(card.compactStatusItems) { item in
                HomeStatusPill(item: item)
            }
        }
        .accessibilityIdentifier("home_card_status_grid")
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppUI.Spacing.small) {
                toggleButton
                previewButton
                webViewButton
                editButton
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                HStack(spacing: AppUI.Spacing.small) {
                    toggleButton
                    previewButton
                }
                HStack(spacing: AppUI.Spacing.small) {
                    webViewButton
                    editButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .appActionButtonStyle(variant: card.isPreviewing ? .danger : .default)
        .disabled(isPreviewActionDisabled)
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
        .appActionButtonStyle(variant: card.isSharing ? .danger : .default)
        .disabled(isWebViewActionDisabled)
        .accessibilityIdentifier("home_virtual_display_web_view_button")
    }

    private var editButton: some View {
        Button {
            perform(.edit)
        } label: {
            Label("Edit", systemImage: "square.and.pencil")
        }
        .appActionButtonStyle(variant: .default)
        .disabled(isBusy)
        .accessibilityIdentifier("virtual_display_edit_button")
    }

    private var moreMenu: some View {
        Menu {
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

private struct HomeSummaryTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            HStack(spacing: AppUI.Spacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(AppUI.Spacing.medium)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

private struct HomeStatusPill: View {
    let item: DisplaySurfaceStatusItemPresentation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isLowPriority = item.tone == .neutral
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isLowPriority ? .secondary : item.tone.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, AppUI.Spacing.small)
        .padding(.vertical, AppUI.Spacing.xSmall)
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

    private func statusFill(isLowPriority: Bool) -> Color {
        if isLowPriority {
            return colorScheme == .dark ? .white.opacity(0.05) : .black.opacity(0.035)
        }
        return item.tone.tint.opacity(colorScheme == .dark ? 0.18 : 0.10)
    }

    private func statusStroke(isLowPriority: Bool) -> Color {
        if isLowPriority {
            return colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)
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
