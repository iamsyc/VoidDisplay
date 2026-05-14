import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
//
//  DisplayView.swift
//  VoidDisplay
//
//

import SwiftUI
import Cocoa
package struct DisplaysShellActions {
    package let openVirtualDisplay: @MainActor () -> Void
    package let openMonitor: @MainActor () -> Void
    package let openLANWebView: @MainActor () -> Void
    package let openDiagnosticsSupport: @MainActor () -> Void

    package init(
        openVirtualDisplay: @escaping @MainActor () -> Void = {},
        openMonitor: @escaping @MainActor () -> Void = {},
        openLANWebView: @escaping @MainActor () -> Void = {},
        openDiagnosticsSupport: @escaping @MainActor () -> Void = {}
    ) {
        self.openVirtualDisplay = openVirtualDisplay
        self.openMonitor = openMonitor
        self.openLANWebView = openLANWebView
        self.openDiagnosticsSupport = openDiagnosticsSupport
    }
}

package struct DisplaysView: View {
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @Environment(\.openURL) private var openURL
    private let activityProvider: any DisplayActivityStatusProviding
    private let actions: DisplaysShellActions
    @State private var displays: [NSScreen]?

    package init(
        activityProvider: any DisplayActivityStatusProviding,
        actions: DisplaysShellActions = DisplaysShellActions()
    ) {
        self.activityProvider = activityProvider
        self.actions = actions
    }

    package var body: some View {
        content
            .onAppear {
                displays = NSScreen.screens
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = NSScreen.screens
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        openDisplaySettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                    .help(String(localized: "Open System Display Settings"))
                    .accessibilityIdentifier("displays_open_system_settings")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppUI.Spacing.large) {
                displaysShellEntries

                if let displays = displays, !displays.isEmpty {
                    displayGrid(displays)
                } else {
                    displayEmptyState
                }
            }
            .appListContentInsets()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("displays_shell")
        }
    }

    private var displaysShellEntries: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 220), spacing: AppUI.List.sectionSpacing, alignment: .top)
            ],
            spacing: AppUI.List.sectionSpacing
        ) {
            ForEach(shellEntries) { entry in
                DisplaysShellEntryButton(entry: entry)
            }
        }
        .accessibilityIdentifier("displays_shell_entries")
    }

    private var shellEntries: [DisplaysShellEntry] {
        [
            DisplaysShellEntry(
                id: "virtual_display",
                title: "Virtual Display",
                systemImage: "display.2",
                accessibilityIdentifier: "displays_shell_virtual_display_entry",
                action: actions.openVirtualDisplay
            ),
            DisplaysShellEntry(
                id: "monitor",
                title: "Monitor",
                systemImage: "dot.scope.display",
                accessibilityIdentifier: "displays_shell_monitor_entry",
                action: actions.openMonitor
            ),
            DisplaysShellEntry(
                id: "lan_web_view",
                title: "LAN Web View",
                systemImage: "network",
                accessibilityIdentifier: "displays_shell_lan_web_view_entry",
                action: actions.openLANWebView
            ),
            DisplaysShellEntry(
                id: "diagnostics_support",
                title: "Diagnostics / Support",
                systemImage: "stethoscope",
                accessibilityIdentifier: "displays_shell_diagnostics_support_entry",
                action: actions.openDiagnosticsSupport
            )
        ]
    }

    @ViewBuilder
    private var displayEmptyState: some View {
        ContentUnavailableView(
            "No display",
            systemImage: "display.trianglebadge.exclamationmark",
            description: Text("Please [go to the settings app](x-apple.systempreferences:com.apple.preference.displays) to adjust the monitor settings.")
        )
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityIdentifier("displays_empty_state")
    }

    private func displayGrid(_ displays: [NSScreen]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 320), spacing: AppUI.List.sectionSpacing, alignment: .top)
            ],
            spacing: AppUI.List.sectionSpacing
        ) {
            ForEach(displays, id: \.self) { display in
                displayRow(display)
            }
        }
        .accessibilityIdentifier("displays_list")
    }

    private func displayRow(_ display: NSScreen) -> some View {
        let displayID = display.cgDirectDisplayID
        let isPrimary = isPrimaryDisplay(displayID)

        let activityStatus = displayID.map {
            activityProvider.activityStatus(for: $0)
        } ?? .inactive
        let iconScreenTint = DisplayIconTintResolver.resolve(
            isMonitoring: activityStatus.isMonitoring,
            isSharing: activityStatus.isSharing
        )

        let model = AppListRowModel(
            id: displayID.map(String.init) ?? display.localizedName,
            title: display.localizedName,
            subtitle: resolutionText(for: display),
            status: nil,
            metaBadges: displayBadges(for: display),
            ribbon: isPrimary
                ? AppCornerRibbonModel(
                    title: String(localized: "Primary Display"),
                    tint: .green
                )
                : nil,
            iconSystemName: "display",
            iconScreenTint: iconScreenTint,
            isEmphasized: true,
            accessibilityIdentifier: "display_row_card"
        )

        return AppListRowCard(model: model, pushTrailingToEdge: false) {
            EmptyView()
        }
    }

    private func resolutionText(for display: NSScreen) -> String {
        // NSScreen.frame is in points; convert to backing coordinates so the UI shows pixel
        // resolution (aligned with SCDisplay-based screens that expose pixel dimensions directly).
        let backingSize = display.convertRectToBacking(display.frame).size
        return "\(Int(backingSize.width)) × \(Int(backingSize.height))"
    }

    private func displayBadges(for display: NSScreen) -> [AppBadgeModel] {
        let displayID = display.cgDirectDisplayID
        let badges: [AppBadgeModel] = [
            AppBadgeModel(
                title: displayTypeLabel(for: displayID),
                style: displayTypeBadgeStyle(for: displayID)
            )
        ]
        return badges
    }

    private func isPrimaryDisplay(_ displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID else {
            return false
        }
        return CGDisplayIsMain(displayID) != 0
    }

    private func openDisplaySettings() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.displays") else {
            return
        }
        openURL(settingsURL)
    }

    private func displayTypeLabel(for displayID: CGDirectDisplayID?) -> String {
        guard let displayID else {
            return String(localized: "Physical Display")
        }
        if virtualDisplay.isManagedVirtualDisplay(displayID: displayID) {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }

    private func displayTypeBadgeStyle(for displayID: CGDirectDisplayID?) -> AppStatusBadge.Style {
        guard let displayID else {
            return .roundedTag(tint: .gray)
        }
        if virtualDisplay.isManagedVirtualDisplay(displayID: displayID) {
            return .roundedTag(tint: .blue)
        }
        return .roundedTag(tint: .gray)
    }
}

@MainActor
private func makeDisplaysPreviewController() -> VirtualDisplayController {
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
    let controller = makeDisplaysPreviewController()
    DisplaysView(activityProvider: StaticDisplayActivityStatusProvider(.inactive))
        .environment(controller)
}

private struct DisplaysShellEntry: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    let accessibilityIdentifier: String
    let action: @MainActor () -> Void
}

private struct DisplaysShellEntryButton: View {
    let entry: DisplaysShellEntry
    @State private var isHovered = false

    var body: some View {
        Button(action: entry.action) {
            HStack(spacing: AppUI.Spacing.medium) {
                Image(systemName: entry.systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: AppUI.List.iconBoxWidth, height: AppUI.List.iconBoxHeight)
                    .appTileStyle()

                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppUI.List.rowHorizontalInset)
            .padding(.vertical, AppUI.List.rowVerticalInset + 1)
            .frame(minHeight: AppUI.List.rowMinHeight + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appInteractiveCardStyle(isHovered: isHovered)
        .onHover { hovered in
            isHovered = hovered
        }
        .accessibilityIdentifier(entry.accessibilityIdentifier)
    }
}
