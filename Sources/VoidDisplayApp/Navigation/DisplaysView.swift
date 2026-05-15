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

        ScrollView {
            VStack(alignment: .leading, spacing: AppUI.Spacing.large) {
                displaysHeader

                if presentation.surfaces.isEmpty {
                    displayEmptyState
                } else {
                    surfaceList(presentation.surfaces)
                }
            }
            .appListContentInsets()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("displays_shell")
        }
        .toolbar {
            ToolbarItem {
                Button {
                    surfaceActions.manageVirtualDisplay()
                } label: {
                    Label("Manage Virtual Display", systemImage: "display.2")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(Text("Manage Virtual Display"))
                .accessibilityIdentifier("displays_action_manage_virtual_display")
            }

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

    private var displaysHeader: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Image(systemName: "display")
                .foregroundStyle(.secondary)
            Text("Displays")
                .font(.headline)
        }
        .accessibilityIdentifier("displays_surface_list")
    }

    private func surfaceList(_ surfaces: [DisplaySurfacePresentation]) -> some View {
        LazyVStack(alignment: .leading, spacing: AppUI.List.sectionSpacing) {
            ForEach(surfaces) { surface in
                DisplaySurfaceManagementCard(
                    model: rowModel(for: surface),
                    surface: surface
                ) { action in
                    perform(action, for: surface)
                }
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
            status: nil,
            metaBadges: rowBadges(for: surface),
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
        [
            AppBadgeModel(
                title: surface.kindText,
                style: .roundedTag(tint: surface.isManagedVirtualDisplay ? .blue : .gray)
            )
        ]
    }

    @MainActor
    private func perform(
        _ action: DisplaySurfaceRowActionPresentation,
        for surface: DisplaySurfacePresentation
    ) {
        switch action.kind {
        case .openMonitor:
            surfaceActions.openMonitor()
        case .stopMonitor:
            if let displayID = surface.displayID {
                surfaceActions.stopMonitor(displayID)
            }
        case .openLANWebView:
            surfaceActions.openLANWebView()
        case .stopLANWebView:
            if let displayID = surface.displayID {
                surfaceActions.stopLANWebViewSharing(displayID)
            }
        }
    }

    @ViewBuilder
    private var displayEmptyState: some View {
        ContentUnavailableView(
            "No Displays",
            systemImage: "display.trianglebadge.exclamationmark",
            description: Text("Create or enable a virtual display to start using HiDPI remote desktop and LAN Web View.")
        )
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityIdentifier("displays_empty_state")
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

private struct DisplaySurfaceManagementCard: View {
    let model: AppListRowModel
    let surface: DisplaySurfacePresentation
    let performAction: @MainActor (DisplaySurfaceRowActionPresentation) -> Void

    @State private var isHovered = false
    @State private var isTechnicalDetailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            headerAndActions

            DisclosureGroup(isExpanded: $isTechnicalDetailsExpanded) {
                DisplaySurfaceStatusGrid(items: surface.technicalStatusItems)
                    .padding(.top, AppUI.Spacing.small)
            } label: {
                Text("Technical Details")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("displays_technical_details")
        }
        .frame(minHeight: AppUI.List.rowMinHeight + 34)
        .padding(.horizontal, AppUI.List.rowHorizontalInset)
        .padding(.vertical, AppUI.List.rowVerticalInset + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appInteractiveCardStyle(isHovered: isHovered)
        .onHover { hovered in
            isHovered = hovered
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(surface.accessibilitySummary))
    }

    private var headerAndActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                identityBlock
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320, alignment: .leading)
                DisplaySurfaceCompactStatusLine(items: surface.compactStatusItems)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: AppUI.Spacing.medium)
                actionBar(alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                identityBlock
                DisplaySurfaceCompactStatusLine(items: surface.compactStatusItems)
                actionBar(alignment: .leading)
            }
        }
    }

    private var identityBlock: some View {
        HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
            DisplaySurfaceIconTile(model: model)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: AppUI.Spacing.xSmall + 2) {
                    Text(model.title)
                        .font(.headline)
                        .foregroundStyle(model.isEmphasized ? .primary : .secondary)
                        .allowsTightening(true)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if model.status != nil || !model.metaBadges.isEmpty {
                    FlowStatusBadges(model: model)
                        .padding(.top, 1)
                }
            }
        }
    }

    private func actionBar(alignment: HorizontalAlignment) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppUI.Spacing.small) {
                ForEach(surface.rowActions) { action in
                    rowActionButton(action)
                }
            }

            VStack(alignment: alignment, spacing: AppUI.Spacing.small) {
                ForEach(surface.rowActions) { action in
                    rowActionButton(action)
                }
            }
        }
        .frame(maxWidth: 320, alignment: alignment == .trailing ? .trailing : .leading)
    }

    private func rowActionButton(_ action: DisplaySurfaceRowActionPresentation) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            performAction(action)
        } label: {
            Label {
                Text(action.title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: action.systemImage)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(action.isDestructive ? .red : nil)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!action.isEnabled)
        .help(Text(action.help))
        .accessibilityLabel(Text(action.title))
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}

private struct DisplaySurfaceIconTile: View {
    let model: AppListRowModel

    var body: some View {
        let screenTint = model.iconScreenTint
            ?? (model.isEmphasized ? DisplayIconTintResolver.enabledIdle : nil)

        if let screenTint {
            Image(systemName: model.iconSystemName)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary.opacity(0.88), screenTint)
                .frame(width: AppUI.List.iconBoxWidth, height: AppUI.List.iconBoxHeight, alignment: .center)
                .appTileStyle()
        } else {
            Image(systemName: model.iconSystemName)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: AppUI.List.iconBoxWidth, height: AppUI.List.iconBoxHeight, alignment: .center)
                .appTileStyle()
        }
    }
}

private struct DisplaySurfaceCompactStatusLine: View {
    let items: [DisplaySurfaceStatusItemPresentation]

    private let columns = [
        GridItem(.adaptive(minimum: 108), spacing: 6, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items) { item in
                DisplaySurfaceCompactStatusPill(item: item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("displays_compact_status_line")
    }
}

private struct DisplaySurfaceCompactStatusPill: View {
    let item: DisplaySurfaceStatusItemPresentation

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Text(item.title)
                .foregroundStyle(.secondary)
            Text(item.value)
                .fontWeight(.semibold)
                .foregroundStyle(item.tone.tint)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, AppUI.Spacing.small - 1)
        .padding(.vertical, AppUI.Spacing.xSmall)
        .background(
            item.tone.tint.opacity(colorScheme == .dark ? 0.18 : 0.10),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(item.tone.tint.opacity(colorScheme == .dark ? 0.28 : 0.20), lineWidth: AppUI.Stroke.subtle)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(item.title): \(item.value)"))
        .accessibilityIdentifier(item.accessibilityIdentifier)
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

private struct FlowStatusBadges: View {
    let model: AppListRowModel

    var body: some View {
        HStack(spacing: 6) {
            if let status = model.status {
                DisplaySurfaceStatusPill(title: status.title, tint: status.tint, showsDot: true)
            }

            ForEach(model.metaBadges) { badge in
                DisplaySurfaceStatusPill(title: badge.title, tint: .secondary, showsDot: false)
                    .opacity(badge.isVisible ? 1 : 0)
                    .accessibilityHidden(!badge.isVisible)
            }
        }
    }
}

private struct DisplaySurfaceStatusPill: View {
    let title: String
    let tint: Color
    let showsDot: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            }

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, AppUI.Spacing.small - 1)
        .padding(.vertical, AppUI.Spacing.xSmall)
        .background(
            tint.opacity(colorScheme == .dark ? 0.20 : 0.12),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(tint.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: AppUI.Stroke.subtle)
        )
        .foregroundStyle(tint)
    }
}

private struct DisplaySurfaceStatusGrid: View {
    let items: [DisplaySurfaceStatusItemPresentation]

    private let columns = [
        GridItem(.adaptive(minimum: 142), spacing: AppUI.Spacing.medium, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: AppUI.Spacing.medium
        ) {
            ForEach(items) { item in
                DisplaySurfaceStatusItemView(item: item)
            }
        }
    }
}

private struct DisplaySurfaceStatusItemView: View {
    let item: DisplaySurfaceStatusItemPresentation

    var body: some View {
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
}
