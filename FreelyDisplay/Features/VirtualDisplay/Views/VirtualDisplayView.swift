//
//  VirtualDisplay.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import OSLog

struct VirtualDisplayView: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State var createView = false
    @State private var editingConfig: EditingConfig?
    @State private var primaryDisplayMonitor = PrimaryDisplayReconfigurationMonitor()
    @State private var primaryDisplayRefreshTick: UInt64 = 0

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
            _ = primaryDisplayMonitor.start {
                primaryDisplayRefreshTick &+= 1
            }
        }
        .onDisappear {
            primaryDisplayMonitor.stop()
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
            let failures = appHelper.restoreFailures.prefix(3)
            let summary = failures
                .map { "\($0.name) (Serial \($0.serialNum)): \($0.message)" }
                .joined(separator: "\n\n")
            let more = appHelper.restoreFailures.count > 3 ? "\n\n…" : ""
            Text(summary + more)
        }
        .appScreenBackground()
    }

    private func virtualDisplayRow(_ config: VirtualDisplayConfig) -> some View {
        let isRunning = appHelper.isVirtualDisplayRunning(configId: config.id)
        let isFirst = appHelper.displayConfigs.first?.id == config.id
        let isLast = appHelper.displayConfigs.last?.id == config.id
        let isPrimary = isPrimaryDisplay(configID: config.id)
        let model = AppListRowModel(
            id: config.id.uuidString,
            title: config.name,
            subtitle: subtitleText(for: config),
            status: AppRowStatus(
                title: displayStatusLabel(isRunning: isRunning),
                tint: isRunning ? .green : .gray
            ),
            metaBadges: [
                AppBadgeModel(
                    title: String(localized: "Virtual Display"),
                    style: .roundedTag(tint: .blue)
                )
            ],
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
                    moveButtons(config: config, isFirst: isFirst, isLast: isLast)

                    Button {
                        toggleDisplayState(config)
                    } label: {
                        Label(
                            toggleButtonTitle(isRunning: isRunning),
                            systemImage: isRunning ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? .orange : .green)
                    .accessibilityIdentifier("virtual_display_toggle_button")

                    Button {
                        editingConfig = EditingConfig(id: config.id)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Edit"))
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
                    .accessibilityIdentifier("virtual_display_delete_button")
                }

                // Narrow layout: Edit / Delete collapsed into menu
                HStack(spacing: AppUI.Spacing.small) {
                    moveButtons(config: config, isFirst: isFirst, isLast: isLast)

                    Button {
                        toggleDisplayState(config)
                    } label: {
                        Label(
                            toggleButtonTitle(isRunning: isRunning),
                            systemImage: isRunning ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? .orange : .green)
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
    private func moveButtons(config: VirtualDisplayConfig, isFirst: Bool, isLast: Bool) -> some View {
        Button {
            _ = appHelper.moveDisplayConfig(config.id, direction: .up)
        } label: {
            Image(systemName: "chevron.up")
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .disabled(isFirst)
        .accessibilityLabel(Text("Move up"))
        .accessibilityIdentifier("virtual_display_move_up_button")

        Button {
            _ = appHelper.moveDisplayConfig(config.id, direction: .down)
        } label: {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .disabled(isLast)
        .accessibilityLabel(Text("Move down"))
        .accessibilityIdentifier("virtual_display_move_down_button")
    }

    private func subtitleText(for config: VirtualDisplayConfig) -> String {
        let serial = "\(String(localized: "Serial Number")): \(config.serialNum)"
        guard let mode = modeSummary(config) else {
            return serial
        }
        return "\(serial) • \(mode)"
    }

    private func modeSummary(_ config: VirtualDisplayConfig) -> String? {
        guard let maxMode = config.modes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
            return nil
        }
        return "\(maxMode.width) × \(maxMode.height)"
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
        if appHelper.isVirtualDisplayRunning(configId: config.id) {
            appHelper.disableDisplayByConfig(config.id)
            return
        }
        do {
            try appHelper.enableDisplay(config.id)
        } catch {
            AppErrorMapper.logFailure("Enable virtual display", error: error, logger: AppLog.virtualDisplay)
            errorMessage = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Enable failed."))
            showError = true
        }
    }

    private func displayStatusLabel(isRunning: Bool) -> String {
        if isRunning {
            return String(localized: "Enable")
        }
        return String(localized: "Disable")
    }

    private func toggleButtonTitle(isRunning: Bool) -> String {
        if isRunning {
            return String(localized: "Disable")
        }
        return String(localized: "Enable")
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
