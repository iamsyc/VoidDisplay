//
//  VirtualDisplay.swift
//  VoidDisplay
//
//

import SwiftUI
import OSLog

struct VirtualDisplayView: View {
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @State var createView = false
    @State private var editingConfig: EditingConfig?
    @State private var primaryDisplayMonitor = DebouncingDisplayReconfigurationMonitor()
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
            if !virtualDisplay.displayConfigs.isEmpty {
                List(virtualDisplay.displayConfigs) { config in
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
                .environment(virtualDisplay)
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
                virtualDisplay.destroyDisplay(config.id)
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
            if !virtualDisplay.restoreFailures.isEmpty {
                showRestoreFailureAlert = true
            }
            startPrimaryDisplayMonitoring()
        }
        .onDisappear {
            stopPrimaryDisplayMonitoring()
        }
        .onChange(of: virtualDisplay.restoreFailures) { _, newValue in
            if !newValue.isEmpty {
                showRestoreFailureAlert = true
            }
        }
        .alert(String(localized: "Restore Failed"), isPresented: $showRestoreFailureAlert) {
            Button("OK") {
                virtualDisplay.clearRestoreFailures()
            }
        } message: {
            Text(VirtualDisplayRowPresentation.restoreFailureSummary(virtualDisplay.restoreFailures))
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
        let isRunning = virtualDisplay.isVirtualDisplayRunning(configId: config.id)
        let isToggling = togglingConfigIds.contains(config.id)
        let isRebuilding = virtualDisplay.isRebuilding(configId: config.id)
        let rebuildFailureMessage = virtualDisplay.rebuildFailureMessage(configId: config.id)
        let hasRecentApplySuccess = virtualDisplay.hasRecentApplySuccess(configId: config.id)
        let isFirst = virtualDisplay.displayConfigs.first?.id == config.id
        let isLast = virtualDisplay.displayConfigs.last?.id == config.id
        let isPrimary = isPrimaryDisplay(configID: config.id)
        return VirtualDisplayRow(
            config: config,
            isRunning: isRunning,
            isToggling: isToggling,
            isRebuilding: isRebuilding,
            rebuildFailureMessage: rebuildFailureMessage,
            hasRecentApplySuccess: hasRecentApplySuccess,
            isFirst: isFirst,
            isLast: isLast,
            isPrimary: isPrimary,
            onMoveUp: { _ = virtualDisplay.moveDisplayConfig(config.id, direction: .up) },
            onMoveDown: { _ = virtualDisplay.moveDisplayConfig(config.id, direction: .down) },
            onToggle: { toggleDisplayState(config) },
            onEdit: { editingConfig = EditingConfig(id: config.id) },
            onDelete: {
                deleteCandidate = config
                showDeleteConfirm = true
            },
            onRetryRebuild: { virtualDisplay.retryRebuild(configId: config.id) }
        )
    }

    private func isPrimaryDisplay(configID: UUID) -> Bool {
        guard let runtimeDisplay = virtualDisplay.runtimeDisplay(for: configID) else {
            return false
        }
        let displayID = runtimeDisplay.displayID
        let mainID = CGMainDisplayID()
        return displayID == mainID
        }
    
    private func toggleDisplayState(_ config: VirtualDisplayConfig) {
        guard !togglingConfigIds.contains(config.id),
              !virtualDisplay.isRebuilding(configId: config.id) else { return }
        togglingConfigIds.insert(config.id)

        Task { @MainActor in
            defer { togglingConfigIds.remove(config.id) }

            if virtualDisplay.isVirtualDisplayRunning(configId: config.id) {
                do {
                    try virtualDisplay.disableDisplayByConfig(config.id)
                } catch {
                    AppErrorMapper.logFailure("Disable virtual display", error: error, logger: AppLog.virtualDisplay)
                    errorMessage = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Disable failed."))
                    showError = true
                }
                return
            }
            do {
                try await virtualDisplay.enableDisplay(config.id)
            } catch {
                AppErrorMapper.logFailure("Enable virtual display", error: error, logger: AppLog.virtualDisplay)
                errorMessage = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Enable failed."))
                showError = true
            }
        }
    }

}

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    VirtualDisplayView()
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}
