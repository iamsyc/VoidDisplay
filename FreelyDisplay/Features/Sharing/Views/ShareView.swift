//
//  shareView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/16.
//

import SwiftUI
import ScreenCaptureKit
import Cocoa
import Combine

struct ShareView: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State private var viewModel = ShareViewModel()
    @Environment(\.openURL) private var openURL
    private let sharingStatsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            shareContent
                .accessibilityIdentifier("share_content_root")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            if appHelper.isWebServiceRunning {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    viewModel.refreshDisplays(appHelper: appHelper)
                }
                Button("Open Share Page") {
                    viewModel.openSharePage(appHelper: appHelper)
                }
                .accessibilityIdentifier("share_open_page_button")
                if appHelper.isSharing {
                    Button("Stop All Sharing") {
                        appHelper.stopAllSharing()
                    }
                    .accessibilityIdentifier("share_stop_all_button")
                }
                Button("Stop Service") {
                    viewModel.stopService(appHelper: appHelper)
                }
                .accessibilityIdentifier("share_stop_service_button")
            }
        }
        .onAppear {
            viewModel.refreshPermissionAndMaybeLoad(appHelper: appHelper)
        }
        .onChange(of: appHelper.isWebServiceRunning) { _, _ in
            viewModel.syncForCurrentState(appHelper: appHelper)
        }
        .onChange(of: appHelper.isSharing) { _, _ in
            viewModel.syncForCurrentState(appHelper: appHelper)
        }
        .onReceive(sharingStatsTimer) { _ in
            guard appHelper.isWebServiceRunning else { return }
            appHelper.refreshSharingClientCount()
        }
        .alert("Error", isPresented: $viewModel.showOpenPageError) {
            Button("OK") {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.openPageErrorMessage)
        }
        .appScreenBackground()
    }

    @ViewBuilder
    private var shareContent: some View {
        if viewModel.hasScreenCapturePermission == false {
            screenCapturePermissionView
        } else if viewModel.hasScreenCapturePermission == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("share_loading_permission")
        } else if !appHelper.isWebServiceRunning {
            VStack(alignment: .leading, spacing: AppUI.Spacing.small + 2) {
                Text("Web service is stopped.")
                    .font(.title3)
                Button("Start service") {
                    viewModel.startService(appHelper: appHelper)
                }
                .accessibilityIdentifier("share_start_service_button")
            }
            .padding(.horizontal, AppUI.Spacing.large)
            .padding(.top, 6)
        } else if viewModel.isLoadingDisplays {
            ProgressView("Loading displays…")
                .padding(.horizontal, AppUI.Spacing.large)
                .padding(.top, 6)
                .accessibilityIdentifier("share_loading_displays")
        } else if let displays = viewModel.displays {
            if displays.isEmpty {
                VStack(spacing: AppUI.Spacing.medium) {
                    Text("No screen to share")
                    Button("Refresh") {
                        viewModel.refreshDisplays(appHelper: appHelper)
                    }
                    .accessibilityIdentifier("share_empty_refresh_button")
                }
                .padding(.horizontal, AppUI.Spacing.large)
                .padding(.top, 6)
                .accessibilityIdentifier("share_displays_empty_state")
            } else {
                VStack(spacing: AppUI.Spacing.small) {
                    shareStatusPanel(displayCount: displays.count)
                        .padding(.horizontal, AppUI.List.listHorizontalInset)
                        .padding(.top, AppUI.Spacing.small + 2)

                    ScrollView {
                        LazyVStack(spacing: AppUI.Spacing.small) {
                            ForEach(displays, id: \.self) { display in
                                shareableDisplayRow(display)
                            }
                        }
                        .padding(.horizontal, AppUI.List.listHorizontalInset)
                        .padding(.bottom, AppUI.Spacing.small)
                        .padding(.top, 2)
                    }
                }
                .accessibilityIdentifier("share_displays_list")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: AppUI.Spacing.small + 2) {
                        Divider()
                        Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, AppUI.Spacing.large)
                    .padding(.top, AppUI.Spacing.small + 2)
                    .padding(.bottom, AppUI.Spacing.medium)
                }
            }
        } else {
            VStack(spacing: AppUI.Spacing.medium) {
                Text("No screen to share")
                Button("Refresh") {
                    viewModel.refreshDisplays(appHelper: appHelper)
                }
                .accessibilityIdentifier("share_empty_refresh_button")
            }
            .padding(.horizontal, AppUI.Spacing.large)
            .padding(.top, 6)
            .accessibilityIdentifier("share_displays_empty_state")
        }
    }

    private func shareStatusPanel(displayCount: Int) -> some View {
        let sharingDisplayCount = appHelper.activeSharingDisplayIDs.count
        let clientsCount = appHelper.sharingClientCount

        return VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: AppUI.Spacing.small) {
                Text(String(localized: "Status"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text(localizedDisplayCount(displayCount))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Divider()

            HStack(spacing: AppUI.Spacing.medium) {
                statusMetricColumn(
                    title: String(localized: "Service"),
                    value: appHelper.isWebServiceRunning ? String(localized: "Running") : String(localized: "Stopped"),
                    tint: appHelper.isWebServiceRunning ? .green : .secondary,
                    showsDot: appHelper.isWebServiceRunning
                )

                Divider()
                    .frame(maxHeight: 34)

                statusMetricColumn(
                    title: String(localized: "Sharing"),
                    value: appHelper.isSharing
                        ? localizedActiveSharingCount(sharingDisplayCount)
                        : String(localized: "Idle"),
                    tint: appHelper.isSharing ? .green : .secondary,
                    showsDot: appHelper.isSharing
                )

                Divider()
                    .frame(maxHeight: 34)

                statusMetricColumn(
                    title: String(localized: "Connected Clients"),
                    value: "\(clientsCount)",
                    tint: clientsCount > 0 ? .accentColor : .secondary
                )
            }
        }
        .padding(.horizontal, AppUI.Spacing.medium)
        .padding(.vertical, AppUI.Spacing.small + 2)
        .background(
            RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.secondary.opacity(0.12),
                            Color.secondary.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: AppUI.Stroke.subtle)
        )
        .accessibilityIdentifier("share_status_panel")
    }

    private func statusMetricColumn(
        title: String,
        value: String,
        tint: Color,
        showsDot: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: AppUI.Spacing.xSmall) {
                if showsDot {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var screenCapturePermissionView: some View {
        ScreenCapturePermissionGuideView(
            loadErrorMessage: viewModel.loadErrorMessage,
            onOpenSettings: {
                viewModel.openScreenCapturePrivacySettings { url in
                    openURL(url)
                }
            },
            onRequestPermission: {
                viewModel.requestScreenCapturePermission(appHelper: appHelper)
            },
            onRefresh: {
                viewModel.refreshPermissionAndMaybeLoad(appHelper: appHelper)
            },
            onRetry: (viewModel.loadErrorMessage != nil || viewModel.lastLoadError != nil) ? {
                // User-initiated retry: attempt to load the display list.
                // If permission is still missing, macOS may prompt here (expected).
                viewModel.loadDisplays(appHelper: appHelper)
            } : nil,
            isDebugInfoExpanded: $viewModel.showDebugInfo,
            debugItems: sharingPermissionDebugItems,
            rootAccessibilityIdentifier: "share_permission_guide",
            openSettingsButtonAccessibilityIdentifier: "share_open_settings_button",
            requestPermissionButtonAccessibilityIdentifier: "share_request_permission_button",
            refreshButtonAccessibilityIdentifier: "share_refresh_button"
        )
    }

    private var sharingPermissionDebugItems: [(title: String, value: String)] {
        var items: [(title: String, value: String)] = [
            (String(localized: "Bundle ID"), Bundle.main.bundleIdentifier ?? "-"),
            (String(localized: "App Path"), Bundle.main.bundleURL.path),
            (
                String(localized: "Preflight Permission"),
                (viewModel.lastPreflightPermission ?? viewModel.hasScreenCapturePermission)
                    .map { $0 ? "true" : "false" } ?? "-"
            ),
            (
                String(localized: "Request Permission Result"),
                viewModel.lastRequestPermission.map { $0 ? "true" : "false" } ?? "-"
            )
        ]

        if let lastLoadError = viewModel.lastLoadError {
            items.append((String(localized: "Last Error"), lastLoadError.description))
            items.append((String(localized: "Error Domain"), lastLoadError.domain))
            items.append((String(localized: "Error Code"), "\(lastLoadError.code)"))

            if let failureReason = lastLoadError.failureReason, !failureReason.isEmpty {
                items.append((String(localized: "Failure Reason"), failureReason))
            }
            if let recoverySuggestion = lastLoadError.recoverySuggestion, !recoverySuggestion.isEmpty {
                items.append((String(localized: "Recovery Suggestion"), recoverySuggestion))
            }
        }
        return items
    }

    private func shareableDisplayRow(_ display: SCDisplay) -> some View {
        let displayName = NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName
            ?? String(localized: "Monitor")
        let isVirtual = isManagedVirtualDisplay(display.displayID)
        let isSharingDisplay = appHelper.isDisplaySharing(displayID: display.displayID)
        let displayAddress = viewModel.sharePageAddress(for: display.displayID, appHelper: appHelper)
        let displayURL = displayAddress.flatMap(URL.init(string:))
        let displayClientCount = appHelper.sharingClientCounts[display.displayID] ?? 0
        let isStartingDisplay = viewModel.startingDisplayID == display.displayID
        let isPrimaryDisplay = CGDisplayIsMain(display.displayID) != 0
        let model = AppListRowModel(
            id: String(display.displayID),
            title: displayName,
            subtitle: "\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))",
            status: nil,
            metaBadges: displayBadges(
                for: display.displayID,
                isVirtual: isVirtual,
                isSharingDisplay: isSharingDisplay
            ),
            ribbon: isPrimaryDisplay
                ? AppCornerRibbonModel(
                    title: String(localized: "Primary Display"),
                    tint: .green
                )
                : nil,
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: nil
        )

        return AppListRowCard(model: model) {
            displayRowTrailing(
                display: display,
                displayAddress: displayAddress,
                displayURL: displayURL,
                displayClientCount: displayClientCount,
                isSharingDisplay: isSharingDisplay,
                isStartingDisplay: isStartingDisplay
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                .stroke(isSharingDisplay ? Color.green.opacity(0.35) : .clear, lineWidth: AppUI.Stroke.subtle)
        }
    }

    @ViewBuilder
    private func displayRowTrailing(
        display: SCDisplay,
        displayAddress: String?,
        displayURL: URL?,
        displayClientCount: Int,
        isSharingDisplay: Bool,
        isStartingDisplay: Bool
    ) -> some View {
        VStack(alignment: .trailing, spacing: AppUI.Spacing.xSmall + 2) {
            if let displayAddress {
                displayAddressCapsule(displayAddress: displayAddress, displayURL: displayURL)
            }

            HStack(spacing: AppUI.Spacing.small) {
                displayClientCountCapsule(
                    displayClientCount: displayClientCount,
                    isSharingDisplay: isSharingDisplay
                )

                shareActionButton(
                    display: display,
                    isSharingDisplay: isSharingDisplay,
                    isStartingDisplay: isStartingDisplay
                )
            }
        }
        .frame(maxWidth: 520, alignment: .trailing)
    }

    private func displayAddressCapsule(displayAddress: String, displayURL: URL?) -> some View {
        HStack(spacing: AppUI.Spacing.xSmall) {
            if let displayURL {
                Button {
                    openURL(displayURL)
                } label: {
                    Image(systemName: "link")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(6)
                        .background(Color.accentColor.opacity(0.16), in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor.opacity(0.28), lineWidth: AppUI.Stroke.subtle)
                        )
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open Share Page"))
                .accessibilityLabel(String(localized: "Open Share Page"))
            }

            Text(displayAddress)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayAddress, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Copy display address"))
        }
        .padding(.horizontal, AppUI.Spacing.small)
        .padding(.vertical, AppUI.Spacing.xSmall + 1)
        .background(Color.secondary.opacity(0.09), in: Capsule(style: .continuous))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func displayClientCountCapsule(displayClientCount: Int, isSharingDisplay: Bool) -> some View {
        HStack(spacing: AppUI.Spacing.xSmall) {
            Image(systemName: "person.2")
                .font(.caption)
            Text("\(displayClientCount)")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .frame(width: 24, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppUI.Spacing.small)
        .padding(.vertical, AppUI.Spacing.xSmall)
        .background(Color.secondary.opacity(0.09), in: Capsule(style: .continuous))
        .opacity(isSharingDisplay ? 1 : 0)
        .frame(width: 74, alignment: .leading)
        .accessibilityHidden(!isSharingDisplay)
        .accessibilityLabel(connectedClientsAccessibilityLabel(displayClientCount))
    }

    private func connectedClientsAccessibilityLabel(_ count: Int) -> String {
        let format = String(localized: "%lld connected")
        return String.localizedStringWithFormat(format, Int64(count))
    }

    private func localizedDisplayCount(_ count: Int) -> String {
        let format = String(localized: "%lld displays")
        return String.localizedStringWithFormat(format, Int64(count))
    }

    private func localizedActiveSharingCount(_ count: Int) -> String {
        let format = String(localized: "%lld active")
        return String.localizedStringWithFormat(format, Int64(count))
    }

    @ViewBuilder
    private func shareActionButton(display: SCDisplay, isSharingDisplay: Bool, isStartingDisplay: Bool) -> some View {
        Button {
            if isSharingDisplay {
                viewModel.stopSharing(displayID: display.displayID, appHelper: appHelper)
            } else {
                Task {
                    await viewModel.startSharing(display: display, appHelper: appHelper)
                }
            }
        } label: {
            if isStartingDisplay {
                ProgressView()
                    .controlSize(.small)
            } else if isSharingDisplay {
                Text(String(localized: "Stop"))
            } else {
                Text(String(localized: "Share"))
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isSharingDisplay ? .red : .accentColor)
        .disabled(viewModel.startingDisplayID != nil && !isSharingDisplay)
    }

    private func displayBadges(
        for displayID: CGDirectDisplayID,
        isVirtual: Bool,
        isSharingDisplay: Bool
    ) -> [AppBadgeModel] {
        var badges: [AppBadgeModel] = []
        badges.append(
            AppBadgeModel(
                title: displayTypeLabel(for: displayID),
                style: displayTypeBadgeStyle(isVirtual: isVirtual)
            )
        )
        badges.append(
            AppBadgeModel(
                title: String(localized: "LIVE"),
                style: .accent(.green),
                isVisible: isSharingDisplay
            )
        )
        return badges
    }

    private func isManagedVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        appHelper.isManagedVirtualDisplay(displayID: displayID)
    }

    private func displayTypeLabel(for displayID: CGDirectDisplayID) -> String {
        if isManagedVirtualDisplay(displayID) {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }

    private func displayTypeBadgeStyle(isVirtual: Bool) -> AppStatusBadge.Style {
        if isVirtual {
            return .roundedTag(tint: .blue)
        }
        return .roundedTag(tint: .gray)
    }
}

#Preview {
    ShareView()
        .environment(AppHelper(preview: true))
}
