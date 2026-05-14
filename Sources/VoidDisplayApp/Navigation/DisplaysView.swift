import AppKit
import CoreGraphics
import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayRuntime

package struct DisplaySurfaceActions {
    package let manageVirtualDisplay: @MainActor () -> Void
    package let openMonitor: @MainActor () -> Void
    package let stopMonitor: @MainActor (CGDirectDisplayID) -> Void
    package let openLANWebView: @MainActor () -> Void
    package let stopLANWebViewSharing: @MainActor (CGDirectDisplayID) -> Void
    package let stopWebService: @MainActor () -> Void
    package let openDiagnostics: @MainActor () -> Void

    package init(
        manageVirtualDisplay: @escaping @MainActor () -> Void = {},
        openMonitor: @escaping @MainActor () -> Void = {},
        stopMonitor: @escaping @MainActor (CGDirectDisplayID) -> Void = { _ in },
        openLANWebView: @escaping @MainActor () -> Void = {},
        stopLANWebViewSharing: @escaping @MainActor (CGDirectDisplayID) -> Void = { _ in },
        stopWebService: @escaping @MainActor () -> Void = {},
        openDiagnostics: @escaping @MainActor () -> Void = {}
    ) {
        self.manageVirtualDisplay = manageVirtualDisplay
        self.openMonitor = openMonitor
        self.stopMonitor = stopMonitor
        self.openLANWebView = openLANWebView
        self.stopLANWebViewSharing = stopLANWebViewSharing
        self.stopWebService = stopWebService
        self.openDiagnostics = openDiagnostics
    }
}

package struct DisplaysView: View {
    @Environment(\.openURL) private var openURL
    private let displayRuntime: DisplayRuntime
    private let surfaceActions: DisplaySurfaceActions
    @State private var selectedSurfaceID: DisplaySurfacePresentation.ID?

    package init(
        displayRuntime: DisplayRuntime,
        surfaceActions: DisplaySurfaceActions = DisplaySurfaceActions()
    ) {
        self.displayRuntime = displayRuntime
        self.surfaceActions = surfaceActions
    }

    package var body: some View {
        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: displayRuntime.makeSnapshot()
        )
        let selectedSurface = selectedSurface(in: presentation)

        ScrollView {
            VStack(alignment: .leading, spacing: AppUI.Spacing.large) {
                if let selectedSurface {
                    surfaceActionStrip(for: selectedSurface)
                }
                surfaceList(presentation.surfaces)

                if let selectedSurface {
                    surfaceDetail(selectedSurface)
                } else {
                    displayEmptyState
                }
            }
            .appListContentInsets()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("displays_shell")
        }
        .onAppear {
            selectInitialSurface(in: presentation)
        }
        .onChange(of: presentation.surfaces.map(\.id)) { _, _ in
            selectInitialSurface(in: presentation)
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

    private func surfaceList(_ surfaces: [DisplaySurfacePresentation]) -> some View {
        LazyVStack(alignment: .leading, spacing: AppUI.List.sectionSpacing) {
            HStack(spacing: AppUI.Spacing.small) {
                Image(systemName: "display")
                    .foregroundStyle(.secondary)
                Text("Displays")
                    .font(.headline)
            }
            .accessibilityIdentifier("displays_surface_list")

            ForEach(surfaces) { surface in
                Button {
                    selectedSurfaceID = surface.id
                } label: {
                    AppListRowCard(
                        model: rowModel(for: surface),
                        pushTrailingToEdge: true
                    ) {
                        Image(systemName: selectedSurfaceID == surface.id ? "checkmark.circle.fill" : "chevron.right")
                            .foregroundStyle(selectedSurfaceID == surface.id ? Color.accentColor : Color.secondary)
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("display_surface_row")
            }
        }
        .accessibilityIdentifier("displays_list")
    }

    private func rowModel(for surface: DisplaySurfacePresentation) -> AppListRowModel {
        AppListRowModel(
            id: surface.id,
            title: surface.title,
            subtitle: surface.subtitle,
            status: surface.hasFailure
                ? AppRowStatus(title: String(localized: "Needs attention"), tint: .red)
                : nil,
            metaBadges: rowBadges(for: surface),
            ribbon: selectedSurfaceID == surface.id
                ? AppCornerRibbonModel(
                    title: String(localized: "Selected"),
                    tint: .accentColor
                )
                : nil,
            iconSystemName: surface.isManagedVirtualDisplay ? "display.2" : "display",
            iconScreenTint: DisplayIconTintResolver.resolve(
                isMonitoring: surface.isMonitoring,
                isSharing: surface.isSharing
            ),
            isEmphasized: true,
            accessibilityIdentifier: "display_surface_card"
        )
    }

    private func rowBadges(for surface: DisplaySurfacePresentation) -> [AppBadgeModel] {
        var badges = [
            AppBadgeModel(
                title: surface.kindText,
                style: .roundedTag(tint: surface.isManagedVirtualDisplay ? .blue : .gray)
            )
        ]
        if surface.isMonitoring {
            badges.append(AppBadgeModel(title: String(localized: "Monitor"), style: .roundedTag(tint: .green)))
        }
        if surface.isSharing {
            badges.append(AppBadgeModel(title: String(localized: "LAN Web View"), style: .roundedTag(tint: .orange)))
        }
        if surface.hasFailure {
            badges.append(AppBadgeModel(title: String(localized: "Failure"), style: .roundedTag(tint: .red)))
        }
        return badges
    }

    private func surfaceDetail(_ surface: DisplaySurfacePresentation) -> some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HStack(spacing: AppUI.Spacing.small) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .foregroundStyle(.secondary)
                Text("Display Details")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            statusGrid(surface.statusItems)
        }
        .padding(.top, AppUI.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("displays_surface_detail")
    }

    private func statusGrid(_ items: [DisplaySurfaceStatusItemPresentation]) -> some View {
        let rows = statusRows(items)
        return Grid(
            alignment: .leading,
            horizontalSpacing: AppUI.Spacing.medium,
            verticalSpacing: AppUI.Spacing.medium
        ) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(rows[rowIndex]) { item in
                        statusItemView(item)
                    }
                }
            }
        }
    }

    private func statusItemView(_ item: DisplaySurfaceStatusItemPresentation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(item.value)
                .font(item.isFailureCode ? .caption.monospaced() : .subheadline.weight(.medium))
                .foregroundStyle(item.isFailureCode ? .orange : .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(item.accessibilityIdentifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func surfaceActionStrip(for surface: DisplaySurfacePresentation) -> some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            HStack(spacing: AppUI.Spacing.small) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                Text("Quick Actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("displays_surface_actions")
                Spacer(minLength: 0)
            }

            HStack(spacing: AppUI.Spacing.small) {
                ForEach(actionEntries(for: surface)) { entry in
                    DisplaySurfaceCompactActionButton(entry: entry)
                }
            }
        }
    }

    private func actionEntries(for surface: DisplaySurfacePresentation) -> [DisplaySurfaceActionEntry] {
        [
            DisplaySurfaceActionEntry(
                id: "manage_virtual_display",
                title: "Manage Virtual Display",
                systemImage: "display.2",
                accessibilityIdentifier: "displays_action_manage_virtual_display",
                isEnabled: true,
                action: surfaceActions.manageVirtualDisplay
            ),
            DisplaySurfaceActionEntry(
                id: "open_monitor",
                title: "Open Monitor",
                systemImage: "dot.scope.display",
                accessibilityIdentifier: "displays_action_open_monitor",
                isEnabled: true,
                action: surfaceActions.openMonitor
            ),
            DisplaySurfaceActionEntry(
                id: "stop_monitor",
                title: "Stop Monitor",
                systemImage: "stop.circle",
                accessibilityIdentifier: "displays_action_stop_monitor",
                isEnabled: surface.canStopMonitor,
                isDestructive: true,
                action: {
                    if let displayID = surface.displayID {
                        surfaceActions.stopMonitor(displayID)
                    }
                }
            ),
            DisplaySurfaceActionEntry(
                id: "open_lan_web_view",
                title: "Open LAN Web View",
                systemImage: "network",
                accessibilityIdentifier: "displays_action_open_lan_web_view",
                isEnabled: true,
                action: surfaceActions.openLANWebView
            ),
            DisplaySurfaceActionEntry(
                id: "stop_lan_web_view",
                title: "Stop LAN Web View",
                systemImage: "stop.circle",
                accessibilityIdentifier: "displays_action_stop_lan_web_view",
                isEnabled: surface.canStopLANWebViewSharing,
                isDestructive: true,
                action: {
                    if let displayID = surface.displayID {
                        surfaceActions.stopLANWebViewSharing(displayID)
                    }
                }
            ),
            DisplaySurfaceActionEntry(
                id: "stop_web_service",
                title: "Stop Web Service",
                systemImage: "power",
                accessibilityIdentifier: "displays_action_stop_web_service",
                isEnabled: surface.canStopWebService,
                isDestructive: true,
                action: surfaceActions.stopWebService
            ),
            DisplaySurfaceActionEntry(
                id: "open_diagnostics",
                title: "Diagnostics",
                systemImage: "stethoscope",
                accessibilityIdentifier: "displays_action_open_diagnostics",
                isEnabled: true,
                action: surfaceActions.openDiagnostics
            )
        ]
    }

    private func statusRows(_ items: [DisplaySurfaceStatusItemPresentation]) -> [[DisplaySurfaceStatusItemPresentation]] {
        stride(from: 0, to: items.count, by: 3).map { startIndex in
            let endIndex = min(startIndex + 3, items.count)
            return Array(items[startIndex..<endIndex])
        }
    }

    @ViewBuilder
    private var displayEmptyState: some View {
        ContentUnavailableView(
            "No Displays",
            systemImage: "display.trianglebadge.exclamationmark",
            description: Text("Runtime display status will appear after refresh.")
        )
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityIdentifier("displays_empty_state")
    }

    private func selectedSurface(in presentation: DisplaySurfaceListPresentation) -> DisplaySurfacePresentation? {
        if let selectedSurfaceID,
           let selected = presentation.surfaces.first(where: { $0.id == selectedSurfaceID }) {
            return selected
        }
        return presentation.surfaces.first
    }

    private func selectInitialSurface(in presentation: DisplaySurfaceListPresentation) {
        guard presentation.surfaces.isEmpty == false else {
            selectedSurfaceID = nil
            return
        }
        if let selectedSurfaceID,
           presentation.surfaces.contains(where: { $0.id == selectedSurfaceID }) {
            return
        }
        selectedSurfaceID = presentation.surfaces.first?.id
    }

    private func openDisplaySettings() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.displays") else {
            return
        }
        openURL(settingsURL)
    }
}

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    DisplaysView(displayRuntime: env.displayRuntime)
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}

private struct DisplaySurfaceActionEntry: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    let accessibilityIdentifier: String
    let isEnabled: Bool
    var isDestructive = false
    let action: @MainActor () -> Void
}

private struct DisplaySurfaceCompactActionButton: View {
    let entry: DisplaySurfaceActionEntry

    var body: some View {
        Button(action: entry.action) {
            Label(entry.title, systemImage: entry.systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 24)
                .foregroundStyle(iconTint)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!entry.isEnabled)
        .accessibilityLabel(Text(entry.title))
        .accessibilityIdentifier(entry.accessibilityIdentifier)
    }

    private var iconTint: Color {
        if entry.isEnabled == false {
            return .secondary
        }
        return entry.isDestructive ? .red : .secondary
    }
}
