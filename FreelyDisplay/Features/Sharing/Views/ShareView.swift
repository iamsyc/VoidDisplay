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
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            statusSummary
            shareContent
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

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Text("Status")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("share_status_summary")

            HStack(spacing: AppUI.Spacing.small) {
                AppStatusBadge(
                    title: statusBadgeTitle(prefix: String(localized: "Service"), value: serviceStatusText),
                    style: appHelper.isWebServiceRunning ? .accent(.green) : .neutral
                )
                AppStatusBadge(
                    title: statusBadgeTitle(prefix: String(localized: "Sharing"), value: sharingStatusText),
                    style: appHelper.isSharing ? .accent(.green) : .neutral
                )
            }

            if appHelper.isWebServiceRunning {
                let mainShareAddress = viewModel.sharePageAddress(appHelper: appHelper)
                HStack(spacing: AppUI.Spacing.medium) {
                    // Address section
                    HStack(spacing: AppUI.Spacing.small) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                        Text(mainShareAddress ?? viewModel.mainShareAddressPlaceholder(appHelper: appHelper))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        if let address = mainShareAddress {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "Copy address"))
                        }
                    }
                    
                    Divider()
                        .frame(height: 16)
                    
                    // Connected clients section
                    HStack(spacing: AppUI.Spacing.small) {
                        Image(systemName: "person.2")
                            .foregroundStyle(.secondary)
                        Text("\(appHelper.sharingClientCount)")
                            .font(.system(.footnote, design: .monospaced))
                            .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, AppUI.Spacing.small + 2)
                .padding(.vertical, AppUI.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appTileStyle()
            }
        }
        .padding(AppUI.Spacing.medium)
        .appPanelStyle()
        .padding(.horizontal, AppUI.Spacing.large)
        .padding(.top, AppUI.Spacing.small + 2)
        .accessibilityElement(children: .contain)
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
                GeometryReader { geometry in
                    let useGrid = geometry.size.width > 500
                    ScrollView {
                        if useGrid {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppUI.Spacing.small) {
                                ForEach(displays, id: \.self) { display in
                                    shareableDisplayRow(display)
                                }
                            }
                            .padding(.horizontal, AppUI.List.listHorizontalInset)
                            .padding(.top, AppUI.Spacing.small + 2)
                        } else {
                            LazyVStack(spacing: AppUI.List.listVerticalInset * 2) {
                                ForEach(displays, id: \.self) { display in
                                    shareableDisplayRow(display)
                                }
                            }
                            .padding(.horizontal, AppUI.List.listHorizontalInset)
                            .padding(.top, AppUI.Spacing.small + 2)
                        }
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
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: nil
        )

        return AppListRowCard(model: model) {
            VStack(alignment: .trailing, spacing: AppUI.Spacing.xSmall) {
                if let displayAddress {
                    HStack(spacing: AppUI.Spacing.xSmall) {
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
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "Copy display address"))
                    }
                }
                Button {
                    if isSharingDisplay {
                        viewModel.stopSharing(displayID: display.displayID, appHelper: appHelper)
                    } else {
                        Task {
                            await viewModel.startSharing(display: display, appHelper: appHelper)
                        }
                    }
                } label: {
                    if viewModel.startingDisplayID == display.displayID {
                        ProgressView()
                            .controlSize(.small)
                    } else if isSharingDisplay {
                        Text(String(localized: "Stop"))
                    } else {
                        Text(String(localized: "Share"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.startingDisplayID != nil && !isSharingDisplay)
            }
        }
    }

    private func displayBadges(
        for displayID: CGDirectDisplayID,
        isVirtual: Bool,
        isSharingDisplay: Bool
    ) -> [AppBadgeModel] {
        var badges: [AppBadgeModel] = []
        if isSharingDisplay {
            badges.append(AppBadgeModel(title: String(localized: "LIVE"), style: .accent(.green)))
        }
        badges.append(
            AppBadgeModel(
                title: displayTypeLabel(for: displayID),
                style: isVirtual ? .accent(.blue) : .neutral
            )
        )
        if CGDisplayIsMain(displayID) != 0 {
            badges.insert(AppBadgeModel(title: String(localized: "Primary Display"), style: .accent(.green)), at: 0)
        }
        return badges
    }

    private func isManagedVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        appHelper.isManagedVirtualDisplay(displayID: displayID)
    }

    private var serviceStatusText: String {
        if appHelper.isWebServiceRunning {
            return String(localized: "Running")
                } else {
            return String(localized: "Stopped")
                }
    }

    private var sharingStatusText: String {
        if appHelper.isSharing {
            return String(localized: "Active")
        }
        return String(localized: "Idle")
    }

    private func statusBadgeTitle(prefix: String, value: String) -> String {
        "\(prefix): \(value)"
    }

    private func displayTypeLabel(for displayID: CGDirectDisplayID) -> String {
        if isManagedVirtualDisplay(displayID) {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }
}

#Preview {
    ShareView()
        .environment(AppHelper(preview: true))
}
