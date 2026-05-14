import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
//
//  VirtualDisplay.swift
//  VoidDisplay
//
//

import SwiftUI
package struct VirtualDisplayView: View {
    private var virtualDisplay: VirtualDisplayController
    private let activityProvider: any DisplayActivityStatusProviding
    @State private var viewModel: VirtualDisplayListViewModel
    @State var createView = false
    @State private var editingConfig: EditingConfig?
    @State private var showConfigStoreErrorDetails = false

    private struct EditingConfig: Identifiable {
        let id: UUID
    }

    package init(
        controller: VirtualDisplayController,
        activityProvider: any DisplayActivityStatusProviding
    ) {
        virtualDisplay = controller
        self.activityProvider = activityProvider
        _viewModel = State(initialValue: VirtualDisplayListViewModel(controller: controller))
    }

    package var body: some View {
        @Bindable var bindableVirtualDisplay = virtualDisplay
        @Bindable var bindableViewModel = viewModel

        let _ = viewModel.primaryDisplayRefreshTick
        content
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
    }

    @ViewBuilder
    private var content: some View {
        if virtualDisplay.configStorePresentation.hasLoadFailure {
            ScrollView {
                configStoreErrorPanel
                    .appListContentInsets()
            }
        } else if !virtualDisplay.displayConfigs.isEmpty {
            virtualDisplayList
        } else {
            ScrollView {
                ContentUnavailableView(
                    "No Managed Virtual Display",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("Click the + button in the top right to create a virtual display.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
                .appListContentInsets()
                .accessibilityIdentifier("virtual_displays_empty_state")
            }
        }
    }

    private var virtualDisplayList: some View {
        ScrollView {
            LazyVStack(spacing: AppUI.List.sectionSpacing) {
                ForEach(virtualDisplay.displayConfigs) { config in
                    virtualDisplayRow(config)
                }
            }
            .appListContentInsets()
        }
        .accessibilityIdentifier("virtual_displays_list")
        .optionalAccessibilityValue(
            UITestRuntime.isEnabled ? Text("\(virtualDisplay.rebuildRequestCount)") : nil
        )
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
                    do {
                        _ = try virtualDisplay.resetVirtualDisplayData()
                    } catch {}
                }
                .accessibilityIdentifier("virtual_display_reset_config_file_button")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
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
        let activityStatus = displayID.map {
            activityProvider.activityStatus(for: $0)
        } ?? .inactive
        let iconScreenTint = DisplayIconTintResolver.resolve(
            isMonitoring: activityStatus.isMonitoring,
            isSharing: activityStatus.isSharing
        )

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
            onMoveUp: { performPersistenceAction { _ = try virtualDisplay.moveDisplayConfig(config.id, direction: .up) } },
            onMoveDown: { performPersistenceAction { _ = try virtualDisplay.moveDisplayConfig(config.id, direction: .down) } },
            onSetAsPrimary: { performPersistenceAction { _ = try virtualDisplay.setPrimaryVirtualDisplayByReordering(config.id) } },
            onToggle: { viewModel.toggleDisplayState(config) },
            onEdit: { editingConfig = EditingConfig(id: config.id) },
            onDelete: { viewModel.requestDelete(config) },
            onRetryRebuild: { virtualDisplay.retryRebuild(configId: config.id) },
            iconScreenTint: iconScreenTint,
            uiTestOpenEditAccessibilityIdentifier: UITestRuntime.isEnabled && isFirst
                ? "virtual_display_open_edit_test_button"
                : nil,
            uiTestShowRebuildingAccessibilityIdentifier: UITestRuntime.isEnabled && isFirst
                ? "virtual_display_show_rebuilding_test_button"
                : nil,
            uiTestShowRebuildFailedAccessibilityIdentifier: UITestRuntime.isEnabled && isFirst
                ? "virtual_display_show_rebuild_failed_test_button"
                : nil,
            onUITestShowRebuilding: UITestRuntime.isEnabled && isFirst
                ? { virtualDisplay.applyUITestPresentationState(scenario: .virtualDisplayRebuilding) }
                : nil,
            onUITestShowRebuildFailed: UITestRuntime.isEnabled && isFirst
                ? { virtualDisplay.applyUITestPresentationState(scenario: .virtualDisplayRebuildFailed) }
                : nil
        )
    }

    private func performPersistenceAction(action: () throws -> Void) {
        do {
            try action()
        } catch {}
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityValue(_ value: Text?) -> some View {
        if let value {
            accessibilityValue(value)
        } else {
            self
        }
    }
}

@MainActor
private func makeVirtualDisplayPreviewController() -> VirtualDisplayController {
    let controller = VirtualDisplayController(
        virtualDisplayFacade: UITestVirtualDisplayFacade(scenario: .baseline),
        appliedBadgeDisplayDuration: .seconds(0.1)
    )
    controller.configureRebuildExecutor { [weak controller] configID, _ in
        guard let controller else { return }
        try await controller.rebuildVirtualDisplay(configId: configID)
    }
    return controller
}

#Preview {
    let controller = makeVirtualDisplayPreviewController()
    VirtualDisplayView(
        controller: controller,
        activityProvider: StaticDisplayActivityStatusProvider(.inactive)
    )
    .environment(controller)
}
