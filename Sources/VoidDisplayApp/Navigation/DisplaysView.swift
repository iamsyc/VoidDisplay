import AppKit
import CoreGraphics
import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayRuntime

package struct DisplaySurfaceActions {
    package let manageVirtualDisplay: @MainActor () -> Void
    package let openPreview: @MainActor () -> Void
    package let stopPreview: @MainActor (CGDirectDisplayID) -> Void
    package let openLANWebView: @MainActor () -> Void
    package let stopLANWebViewSharing: @MainActor (CGDirectDisplayID) -> Void

    package init(
        manageVirtualDisplay: @escaping @MainActor () -> Void = {},
        openPreview: @escaping @MainActor () -> Void = {},
        stopPreview: @escaping @MainActor (CGDirectDisplayID) -> Void = { _ in },
        openLANWebView: @escaping @MainActor () -> Void = {},
        stopLANWebViewSharing: @escaping @MainActor (CGDirectDisplayID) -> Void = { _ in }
    ) {
        self.manageVirtualDisplay = manageVirtualDisplay
        self.openPreview = openPreview
        self.stopPreview = stopPreview
        self.openLANWebView = openLANWebView
        self.stopLANWebViewSharing = stopLANWebViewSharing
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
    }

    private var displaysHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                displayTitle
                Spacer(minLength: AppUI.Spacing.large)
                headerActions
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                displayTitle
                headerActions
            }
        }
        .accessibilityIdentifier("displays_surface_list")
    }

    private var displayTitle: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Image(systemName: "display")
                .foregroundStyle(.secondary)
            Text("Displays")
                .font(.headline)
        }
    }

    private var headerActions: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Button {
                surfaceActions.manageVirtualDisplay()
            } label: {
                Label("Manage Virtual Displays", systemImage: "display.2")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(Text("Manage Virtual Displays"))
            .accessibilityIdentifier("displays_action_manage_virtual_display")

            Button {
                openDisplaySettings()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(String(localized: "Open System Display Settings"))
            .accessibilityIdentifier("displays_open_system_settings")
        }
    }

    private func surfaceList(_ surfaces: [DisplaySurfacePresentation]) -> some View {
        LazyVStack(alignment: .leading, spacing: AppUI.List.sectionSpacing - 2) {
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
            metaBadges: [],
            iconSystemName: surface.isManagedVirtualDisplay ? "display.2" : "display",
            iconScreenTint: DisplayIconTintResolver.resolve(
                isPreviewing: surface.isPreviewing,
                isSharing: surface.isSharing
            ),
            isEmphasized: true,
            accessibilityIdentifier: "display_surface_card"
        )
    }

    @MainActor
    private func perform(
        _ action: DisplaySurfaceRowActionPresentation,
        for surface: DisplaySurfacePresentation
    ) {
        switch action.kind {
        case .openPreview:
            surfaceActions.openPreview()
        case .stopPreview:
            if let displayID = surface.displayID {
                surfaceActions.stopPreview(displayID)
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

private struct DisplaySurfaceManagementCard: View {
    let model: AppListRowModel
    let surface: DisplaySurfacePresentation
    let performAction: @MainActor (DisplaySurfaceRowActionPresentation) -> Void

    @State private var isTechnicalDetailsExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerAndActions

            if isTechnicalDetailsExpanded {
                Divider()
                    .padding(.horizontal, AppUI.List.rowHorizontalInset)
                DisplaySurfaceStatusGrid(items: surface.technicalStatusItems)
                    .padding(.horizontal, AppUI.List.rowHorizontalInset)
                    .padding(.vertical, AppUI.Spacing.small)
                    .accessibilityIdentifier("displays_technical_details_panel")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(rowStroke, lineWidth: AppUI.Stroke.subtle)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(surface.accessibilitySummary))
    }

    private var headerAndActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                identityBlock
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 300, alignment: .leading)
                DisplaySurfaceCompactStatusLine(items: surface.compactStatusItems)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: AppUI.Spacing.medium)
                rowControls(alignment: .trailing)
            }
            .frame(minHeight: AppUI.List.rowMinHeight + 6)
            .padding(.horizontal, AppUI.List.rowHorizontalInset)
            .padding(.vertical, AppUI.List.rowVerticalInset)

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                identityBlock
                DisplaySurfaceCompactStatusLine(items: surface.compactStatusItems)
                rowControls(alignment: .leading)
            }
            .padding(.horizontal, AppUI.List.rowHorizontalInset)
            .padding(.vertical, AppUI.List.rowVerticalInset)
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
            }
        }
    }

    private func rowControls(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: AppUI.Spacing.xSmall) {
            actionBar(alignment: alignment)
            Button {
                isTechnicalDetailsExpanded.toggle()
            } label: {
                Label("Details", systemImage: "info.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(Text("Details"))
            .accessibilityIdentifier("displays_technical_details")
        }
        .frame(maxWidth: 320, alignment: alignment == .trailing ? .trailing : .leading)
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
        .accessibilityLabel(Text(action.help))
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }

    private var rowFill: Color {
        colorScheme == .dark
            ? .white.opacity(0.035)
            : Color(nsColor: .controlBackgroundColor).opacity(0.62)
    }

    private var rowStroke: Color {
        colorScheme == .dark
            ? .white.opacity(0.10)
            : .black.opacity(0.06)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    DisplaySurfaceCompactStatusPill(item: item)
                }
            }

            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(items) { item in
                    DisplaySurfaceCompactStatusPill(item: item)
                }
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
        let isLowPriority = item.tone == .neutral
        HStack(spacing: 4) {
            Text(item.title)
                .foregroundStyle(.secondary)
            Text(item.value)
                .fontWeight(.semibold)
                .foregroundStyle(isLowPriority ? .secondary : item.tone.tint)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, AppUI.Spacing.small - 1)
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
