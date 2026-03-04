//
//  VirtualDisplay.swift
//  VoidDisplay
//
//

import SwiftUI
import OSLog

struct VirtualDisplayView: View {
    @Bindable private var virtualDisplay: VirtualDisplayController
    @Environment(CaptureController.self) private var capture
    @Environment(SharingController.self) private var sharing
    @State private var viewModel: VirtualDisplayListViewModel
    @State var createView = false
    @State private var editingConfig: EditingConfig?
    @State private var showConfigStoreErrorDetails = false

    private struct EditingConfig: Identifiable {
        let id: UUID
    }

    init(controller: VirtualDisplayController) {
        _virtualDisplay = Bindable(controller)
        _viewModel = State(initialValue: VirtualDisplayListViewModel(controller: controller))
    }

    var body: some View {
        let _ = viewModel.primaryDisplayRefreshTick
        Group {
            if virtualDisplay.configStorePresentation.hasLoadFailure {
                configStoreErrorPanel
            } else if !virtualDisplay.displayConfigs.isEmpty {
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
            if !virtualDisplay.configStorePresentation.hasLoadFailure {
                Button("Add Virtual Display", systemImage: "plus") {
                    createView = true
                }
                .accessibilityIdentifier("virtual_display_add_button")
            }
        }
        .confirmationDialog(
            "Delete Virtual Display",
            isPresented: $viewModel.showDeleteConfirm,
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
        .alert("Enable Failed", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .onAppear {
            viewModel.handleAppear()
        }
        .onDisappear {
            viewModel.handleDisappear()
        }
        .onChange(of: virtualDisplay.restoreFailures) { _, newValue in
            viewModel.handleRestoreFailuresChanged(newValue)
        }
        .alert(String(localized: "Restore Failed"), isPresented: $viewModel.showRestoreFailureAlert) {
            Button("OK") {
                viewModel.acknowledgeRestoreFailures()
            }
        } message: {
            Text(VirtualDisplayRowPresentation.restoreFailureSummary(virtualDisplay.restoreFailures))
        }
        .appScreenBackground()
    }

    private var configStoreErrorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    isExpanded: $showConfigStoreErrorDetails,
                    content: {
                        Text(diagnostics)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    },
                    label: {
                        Text("Details")
                    }
                )
            }

            HStack(spacing: 12) {
                Button("Reset Config File", role: .destructive) {
                    _ = virtualDisplay.resetVirtualDisplayData()
                }
                .accessibilityIdentifier("virtual_display_reset_config_file_button")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .padding()
        .accessibilityIdentifier("virtual_display_config_store_error_panel")
    }

    private func virtualDisplayRow(_ config: VirtualDisplayConfig) -> some View {
        let isRunning = virtualDisplay.isVirtualDisplayRunning(configId: config.id)
        let isToggling = viewModel.isToggling(configId: config.id)
        let isRebuilding = virtualDisplay.isRebuilding(configId: config.id)
        let rebuildFailureMessage = virtualDisplay.rebuildFailureMessage(configId: config.id)
        let hasRecentApplySuccess = virtualDisplay.hasRecentApplySuccess(configId: config.id)
        let isFirst = virtualDisplay.displayConfigs.first?.id == config.id
        let isLast = virtualDisplay.displayConfigs.last?.id == config.id
        let isPrimary = viewModel.isPrimaryDisplay(configID: config.id)
        let isFirstEnabled = virtualDisplay.displayConfigs.first(where: \.desiredEnabled)?.id == config.id
        let canSetAsPrimary = config.desiredEnabled && !isFirstEnabled && !isToggling && !isRebuilding

        let displayID = virtualDisplay.runtimeDisplayID(for: config.id)
        let isMonitoring = displayID.map { did in
            capture.screenCaptureSessions.contains { $0.displayID == did }
        } ?? false
        let isSharing = displayID.map { did in
            sharing.isDisplaySharing(displayID: did)
        } ?? false
        let iconScreenTint = DisplayIconTintResolver.resolve(isMonitoring: isMonitoring, isSharing: isSharing)

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
            canSetAsPrimary: canSetAsPrimary,
            onMoveUp: { _ = virtualDisplay.moveDisplayConfig(config.id, direction: .up) },
            onMoveDown: { _ = virtualDisplay.moveDisplayConfig(config.id, direction: .down) },
            onSetAsPrimary: { _ = virtualDisplay.setPrimaryVirtualDisplayByReordering(config.id) },
            onToggle: { viewModel.toggleDisplayState(config) },
            onEdit: { editingConfig = EditingConfig(id: config.id) },
            onDelete: { viewModel.requestDelete(config) },
            onRetryRebuild: { virtualDisplay.retryRebuild(configId: config.id) },
            iconScreenTint: iconScreenTint
        )
    }

}

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    VirtualDisplayView(controller: env.virtualDisplay)
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}
