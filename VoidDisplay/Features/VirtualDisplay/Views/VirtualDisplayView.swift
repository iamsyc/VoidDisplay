//
//  VirtualDisplay.swift
//  VoidDisplay
//
//

import SwiftUI
import OSLog

struct VirtualDisplayView: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State var createView = false
    @State private var editingConfig: EditingConfig?
    @State private var primaryDisplayMonitor = PrimaryDisplayReconfigurationMonitor()
    @State private var primaryDisplayRefreshTick: UInt64 = 0
    @State private var primaryDisplayFallbackCoordinator = PrimaryDisplayFallbackCoordinator()
    @State private var togglingConfigIds: Set<UUID> = []

    @State private var showDeleteConfirm = false
    @State private var deleteCandidate: VirtualDisplayConfig?
    @State private var showRestoreFailureAlert = false

    private struct EditingConfig: Identifiable {
        let id: UUID
    }
    
    // Error handling
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        let _ = primaryDisplayRefreshTick
        Group {
            if !appHelper.displayConfigs.isEmpty {
                List(appHelper.displayConfigs) { config in
                    virtualDisplayRow(config)
                        .appListRowStyle()
                }
                .accessibilityIdentifier("virtual_displays_list")
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView(
                    "No Virtual Displays",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("Click the + button in the top right to create a virtual display.")
                )
                .accessibilityIdentifier("virtual_displays_empty_state")
            }
        }
        .sheet(isPresented: $createView) {
            CreateVirtualDisplay(isShow: $createView)
        }
        .sheet(item: $editingConfig) { item in
            EditVirtualDisplayConfigView(configId: item.id)
                .environment(appHelper)
        }
        .toolbar {
            Button("Add Virtual Display", systemImage: "plus") {
                createView = true
            }
            .accessibilityIdentifier("virtual_display_add_button")
        }
        .confirmationDialog(
            "Delete Virtual Display",
            isPresented: $showDeleteConfirm,
            presenting: deleteCandidate
        ) { config in
            Button("Delete", role: .destructive) {
                appHelper.destroyDisplay(config.id)
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { config in
            Text("This will remove the configuration and disable the display if it is running.\n\n\(config.name) (Serial \(config.serialNum))")
        }
        .alert("Enable Failed", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            if !appHelper.restoreFailures.isEmpty {
                showRestoreFailureAlert = true
            }
            startPrimaryDisplayMonitoring()
        }
        .onDisappear {
            stopPrimaryDisplayMonitoring()
        }
        .onChange(of: appHelper.restoreFailures) { _, newValue in
            if !newValue.isEmpty {
                showRestoreFailureAlert = true
            }
        }
        .alert(String(localized: "Restore Failed"), isPresented: $showRestoreFailureAlert) {
            Button("OK") {
                appHelper.clearRestoreFailures()
            }
        } message: {
            Text(VirtualDisplayRowPresentation.restoreFailureSummary(appHelper.restoreFailures))
        }
        .appScreenBackground()
    }

    private func startPrimaryDisplayMonitoring() {
        let started = primaryDisplayMonitor.start {
            primaryDisplayRefreshTick &+= 1
        }
        if started {
            primaryDisplayFallbackCoordinator.stop()
            return
        }

        AppLog.virtualDisplay.error(
            "Primary display monitor callback registration failed; enabling polling fallback."
        )
        startPrimaryDisplayFallback()
    }

    private func stopPrimaryDisplayMonitoring() {
        primaryDisplayMonitor.stop()
        primaryDisplayFallbackCoordinator.stop()
    }

    private func startPrimaryDisplayFallback() {
        primaryDisplayFallbackCoordinator.startIfNeeded(
            onTick: {
                primaryDisplayRefreshTick &+= 1
            },
            attemptRecovery: {
                primaryDisplayMonitor.start {
                    primaryDisplayRefreshTick &+= 1
                }
            },
            onRecovered: {
                AppLog.virtualDisplay.notice(
                    "Primary display monitor callback recovered; disabling polling fallback."
                )
            }
        )
    }

    private func virtualDisplayRow(_ config: VirtualDisplayConfig) -> some View {
        let isRunning = appHelper.isVirtualDisplayRunning(configId: config.id)
        let isToggling = togglingConfigIds.contains(config.id)
        let isRebuilding = appHelper.isRebuilding(configId: config.id)
        let rebuildFailureMessage = appHelper.rebuildFailureMessage(configId: config.id)
        let hasRecentApplySuccess = appHelper.hasRecentApplySuccess(configId: config.id)
        let isRowBusy = isToggling || isRebuilding
        let isFirst = appHelper.displayConfigs.first?.id == config.id
        let isLast = appHelper.displayConfigs.last?.id == config.id
        let isPrimary = isPrimaryDisplay(configID: config.id)
        let model = AppListRowModel(
            id: config.id.uuidString,
            title: config.name,
            subtitle: VirtualDisplayRowPresentation.subtitleText(for: config),
            status: AppRowStatus(
                title: VirtualDisplayRowPresentation.statusLabel(isRunning: isRunning, isRebuilding: isRebuilding),
                tint: VirtualDisplayRowPresentation.statusTint(isRunning: isRunning, isRebuilding: isRebuilding)
            ),
            metaBadges: VirtualDisplayRowPresentation.badges(
                rebuildFailureMessage: rebuildFailureMessage,
                hasRecentApplySuccess: hasRecentApplySuccess
            ),
            ribbon: isPrimary
                ? AppCornerRibbonModel(
                    title: String(localized: "Primary Display"),
                    tint: .green
                )
                : nil,
            iconSystemName: "display",
            isEmphasized: isRunning,
            accessibilityIdentifier: "virtual_display_row_card"
        )

        return AppListRowCard(model: model) {
            ViewThatFits(in: .horizontal) {
                // Wide layout: inline Edit / Delete buttons
                HStack(spacing: AppUI.Spacing.small) {
                    moveButtons(config: config, isFirst: isFirst, isLast: isLast, isBusy: isRowBusy)
                    rebuildAction(
                        configId: config.id,
                        isRebuilding: isRebuilding,
                        rebuildFailureMessage: rebuildFailureMessage,
                        isRowBusy: isRowBusy
                    )

                    Button {
                        toggleDisplayState(config)
                    } label: {
                        Label(
                            VirtualDisplayRowPresentation.toggleButtonTitle(isRunning: isRunning),
                            systemImage: isRunning ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? .orange : .green)
                    .disabled(isRowBusy)
                    .accessibilityIdentifier("virtual_display_toggle_button")

                    Button {
                        editingConfig = EditingConfig(id: config.id)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Edit"))
                    .disabled(isRowBusy)
                    .accessibilityIdentifier("virtual_display_edit_button")

                    Button {
                        deleteCandidate = config
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Delete"))
                    .disabled(isRowBusy)
                    .accessibilityIdentifier("virtual_display_delete_button")
                }

                // Narrow layout: Edit / Delete collapsed into menu
                HStack(spacing: AppUI.Spacing.small) {
                    moveButtons(config: config, isFirst: isFirst, isLast: isLast, isBusy: isRowBusy)
                    rebuildAction(
                        configId: config.id,
                        isRebuilding: isRebuilding,
                        rebuildFailureMessage: rebuildFailureMessage,
                        isRowBusy: isRowBusy
                    )

                    Button {
                        toggleDisplayState(config)
                    } label: {
                        Label(
                            VirtualDisplayRowPresentation.toggleButtonTitle(isRunning: isRunning),
                            systemImage: isRunning ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? .orange : .green)
                    .disabled(isRowBusy)
                    .accessibilityIdentifier("virtual_display_toggle_button")

                    AppQuickActionsMenu {
                        Button(String(localized: "Edit"), systemImage: "pencil") {
                            editingConfig = EditingConfig(id: config.id)
                        }

                        Divider()

                        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                            deleteCandidate = config
                            showDeleteConfirm = true
                        }
                    }
                    .disabled(isRowBusy)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                .stroke(isRunning ? Color.green.opacity(0.35) : .clear, lineWidth: AppUI.Stroke.subtle)
        }
        .opacity(isRunning ? 1.0 : 0.82)
    }

    @ViewBuilder
    private func moveButtons(config: VirtualDisplayConfig, isFirst: Bool, isLast: Bool, isBusy: Bool) -> some View {
        Button {
            _ = appHelper.moveDisplayConfig(config.id, direction: .up)
        } label: {
            Image(systemName: "chevron.up")
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .disabled(isFirst || isBusy)
        .accessibilityLabel(Text("Move up"))
        .accessibilityIdentifier("virtual_display_move_up_button")

        Button {
            _ = appHelper.moveDisplayConfig(config.id, direction: .down)
        } label: {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .disabled(isLast || isBusy)
        .accessibilityLabel(Text("Move down"))
        .accessibilityIdentifier("virtual_display_move_down_button")
    }

    @ViewBuilder
    private func rebuildAction(
        configId: UUID,
        isRebuilding: Bool,
        rebuildFailureMessage: String?,
        isRowBusy: Bool
    ) -> some View {
        if isRebuilding {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Rebuilding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("virtual_display_rebuild_progress")
        } else if let rebuildFailureMessage {
            Button("Retry Rebuild") {
                appHelper.retryRebuild(configId: configId)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isRowBusy)
            .help(rebuildFailureMessage)
            .accessibilityIdentifier("virtual_display_rebuild_retry_button")
        }
    }

    private func isPrimaryDisplay(configID: UUID) -> Bool {
        guard let runtimeDisplay = appHelper.runtimeDisplay(for: configID) else {
            return false
        }
        let displayID = runtimeDisplay.displayID
        let mainID = CGMainDisplayID()
        return displayID == mainID
    }
    
    private func toggleDisplayState(_ config: VirtualDisplayConfig) {
        guard !togglingConfigIds.contains(config.id),
              !appHelper.isRebuilding(configId: config.id) else { return }
        togglingConfigIds.insert(config.id)

        Task { @MainActor in
            defer { togglingConfigIds.remove(config.id) }

            if appHelper.isVirtualDisplayRunning(configId: config.id) {
                do {
                    try appHelper.disableDisplayByConfig(config.id)
                } catch {
                    AppErrorMapper.logFailure("Disable virtual display", error: error, logger: AppLog.virtualDisplay)
                    errorMessage = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Disable failed."))
                    showError = true
                }
                return
            }
            do {
                try await appHelper.enableDisplay(config.id)
            } catch {
                AppErrorMapper.logFailure("Enable virtual display", error: error, logger: AppLog.virtualDisplay)
                errorMessage = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Enable failed."))
                showError = true
            }
        }
    }

}

#Preview {
    VirtualDisplayView()
        .environment(AppHelper(preview: true))
}

@MainActor
private final class PrimaryDisplayReconfigurationMonitor {
    private var handler: (@MainActor () -> Void)?
    private var debounceTask: Task<Void, Never>?
    nonisolated(unsafe) private var isRunning = false

    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        self.handler = handler
        guard !isRunning else { return true }

        let userInfo = Unmanaged.passRetained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        guard result == .success else {
            Unmanaged<PrimaryDisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
            return false
        }
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else {
            handler = nil
            debounceTask?.cancel()
            debounceTask = nil
            return
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        isRunning = false
        handler = nil
        debounceTask?.cancel()
        debounceTask = nil
        Unmanaged<PrimaryDisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
    }

    deinit {
        assert(!isRunning, "PrimaryDisplayReconfigurationMonitor must be stopped before deallocation.")
    }

    private func handleDisplayChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.handler?()
        }
    }

    private nonisolated static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
        _,
        _,
        userInfo in
        guard let userInfo else { return }

        let monitor = Unmanaged<PrimaryDisplayReconfigurationMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        Task { @MainActor in
            monitor.handleDisplayChange()
        }
    }
}
