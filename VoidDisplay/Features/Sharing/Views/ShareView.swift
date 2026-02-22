//
//  shareView.swift
//  VoidDisplay
//
//

import SwiftUI
import ScreenCaptureKit
import Cocoa
import Combine
import CoreGraphics
import OSLog

struct ShareView: View {
    private enum ShareAccessibilityState {
        static let sharing = "sharing"
        static let idle = "idle"
    }

    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State private var viewModel = ShareViewModel()
    @State private var displayReconfigurationMonitor = DisplayReconfigurationMonitor()
    @State private var displayRefreshFallbackTask: Task<Void, Never>?
    @State private var showToolbarRefresh = false
    @Environment(\.openURL) private var openURL
    private let sharingStatsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        shareContent
            .accessibilityIdentifier("share_content_root")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            if appHelper.isWebServiceRunning {
                if showToolbarRefresh {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        viewModel.refreshDisplays(appHelper: appHelper)
                    }
                }
                Button("Stop Service") {
                    viewModel.stopService(appHelper: appHelper)
                }
                .accessibilityIdentifier("share_stop_service_button")
            }
        }
        .onAppear {
            viewModel.refreshPermissionAndMaybeLoad(appHelper: appHelper)
            startDisplayReconfigurationMonitoring()
        }
        .onDisappear {
            stopDisplayReconfigurationMonitoring()
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

    private func startDisplayReconfigurationMonitoring() {
        let registered = displayReconfigurationMonitor.start {
            guard viewModel.hasScreenCapturePermission == true else { return }
            viewModel.refreshDisplays(appHelper: appHelper)
        }
        showToolbarRefresh = !registered
        if registered {
            stopDisplayRefreshFallbackPolling()
            return
        }

        AppLog.sharing.error(
            "Display reconfiguration callback registration failed in sharing view; enabling polling fallback."
        )
        startDisplayRefreshFallbackPolling()
    }

    private func stopDisplayReconfigurationMonitoring() {
        displayReconfigurationMonitor.stop()
        stopDisplayRefreshFallbackPolling()
    }

    private func startDisplayRefreshFallbackPolling() {
        guard displayRefreshFallbackTask == nil else { return }
        displayRefreshFallbackTask = Task { @MainActor in
            var cycle: Int = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard viewModel.hasScreenCapturePermission == true else { continue }

                viewModel.refreshDisplays(appHelper: appHelper)
                cycle += 1
                if cycle % 5 != 0 { continue }

                let recovered = displayReconfigurationMonitor.start {
                    guard viewModel.hasScreenCapturePermission == true else { return }
                    viewModel.refreshDisplays(appHelper: appHelper)
                }
                if recovered {
                    showToolbarRefresh = false
                    AppLog.sharing.notice(
                        "Display reconfiguration callback recovered in sharing view; disabling polling fallback."
                    )
                    stopDisplayRefreshFallbackPolling()
                    break
                }
            }
        }
    }

    private func stopDisplayRefreshFallbackPolling() {
        displayRefreshFallbackTask?.cancel()
        displayRefreshFallbackTask = nil
    }

    @ViewBuilder
    private var shareContent: some View {
        if viewModel.hasScreenCapturePermission == false {
            screenCapturePermissionView
        } else if viewModel.hasScreenCapturePermission == nil {
            ScrollView {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            .accessibilityIdentifier("share_loading_permission")
        } else if !appHelper.isWebServiceRunning {
            ScrollView {
                VStack(spacing: AppUI.Spacing.medium + 2) {
                    Image(systemName: "xserve")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)

                    Text("Web service is not running.")
                        .font(.headline)

                    Text("Start the Web service to share your screen with other devices.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)

                    Button("Start Service") {
                        viewModel.startService(appHelper: appHelper)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("share_start_service_button")
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        } else if viewModel.isLoadingDisplays {
            ScrollView {
                ProgressView("Loading displays…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
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
        let isRunning = appHelper.isWebServiceRunning

        return HStack(spacing: AppUI.Spacing.medium) {
            HStack(spacing: AppUI.Spacing.xSmall) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(isRunning ? String(localized: "Service Running") : String(localized: "Service Stopped"))
                    .foregroundStyle(isRunning ? .primary : .secondary)
            }

            Text("·").foregroundStyle(.quaternary)

            HStack(spacing: AppUI.Spacing.xSmall) {
                Text(String(localized: "Sharing"))
                    .foregroundStyle(.secondary)
                Text("\(sharingDisplayCount)/\(displayCount)")
                    .foregroundStyle(sharingDisplayCount > 0 ? Color.green : .secondary)
            }

            Text("·").foregroundStyle(.quaternary)

            HStack(spacing: AppUI.Spacing.xSmall) {
                Image(systemName: "person.2")
                    .foregroundStyle(clientsCount > 0 ? Color.accentColor : .secondary)
                Text("\(clientsCount)")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(localizedDisplayCount(displayCount))
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, AppUI.Spacing.medium)
        .padding(.vertical, AppUI.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .accessibilityIdentifier("share_status_panel")
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
        let isPrimaryDisplay = CGDisplayIsMain(display.displayID) != 0
        let model = AppListRowModel(
            id: String(display.displayID),
            title: displayName,
            subtitle: "\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))",
            status: AppRowStatus(
                title: isSharingDisplay
                    ? String(localized: "Sharing in Progress")
                    : String(localized: "Not Sharing"),
                tint: isSharingDisplay ? .green : .gray
            ),
            metaBadges: displayTypeBadges(
                for: display.displayID,
                isVirtual: isVirtual
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
                isSharingDisplay: isSharingDisplay
            )
        }
    }

    @ViewBuilder
    private func displayRowTrailing(
        display: SCDisplay,
        displayAddress: String?,
        displayURL: URL?,
        displayClientCount: Int,
        isSharingDisplay: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            if let displayAddress {
                displayAddressInline(
                    displayID: display.displayID,
                    displayAddress: displayAddress,
                    displayURL: displayURL,
                    isSharingDisplay: isSharingDisplay
                )
            }

            displayClientCountLabel(
                displayClientCount: displayClientCount
            )

            shareActionButton(
                display: display,
                isSharingDisplay: isSharingDisplay
            )
        }
        .frame(maxWidth: 520, alignment: .trailing)
    }

    private func displayAddressInline(
        displayID: CGDirectDisplayID,
        displayAddress: String,
        displayURL: URL?,
        isSharingDisplay: Bool
    ) -> some View {
        HStack(spacing: AppUI.Spacing.xSmall) {
            if let displayURL {
                Button {
                    openURL(displayURL)
                } label: {
                    Image(systemName: "link")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSharingDisplay ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isSharingDisplay)
                .help(String(localized: "Open Share Page"))
                .accessibilityLabel(String(localized: "Open Share Page"))
            }

            Text(displayAddress)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("share_display_address_\(displayID)")

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
    }

    private func displayClientCountLabel(displayClientCount: Int) -> some View {
        HStack(spacing: AppUI.Spacing.xSmall) {
            Image(systemName: "person.2")
                .font(.caption)
                .foregroundStyle(displayClientCount > 0 ? Color.accentColor : .secondary)
            Text("\(displayClientCount)")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
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
    private func shareActionButton(display: SCDisplay, isSharingDisplay: Bool) -> some View {
        Button {
            if isSharingDisplay {
                viewModel.stopSharing(displayID: display.displayID, appHelper: appHelper)
            } else {
                Task {
                    await viewModel.startSharing(display: display, appHelper: appHelper)
                }
            }
        } label: {
            ZStack {
                Label(String(localized: "Share"), systemImage: "play.fill").hidden()
                Label(String(localized: "Stop"), systemImage: "stop.fill").hidden()

                if isSharingDisplay {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                } else {
                    Label(String(localized: "Share"), systemImage: "play.fill")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isSharingDisplay ? .red : .accentColor)
        .accessibilityIdentifier("share_action_button_\(display.displayID)")
        .accessibilityValue(
            Text(verbatim: isSharingDisplay ? ShareAccessibilityState.sharing : ShareAccessibilityState.idle)
        )
    }

    private func displayTypeBadges(
        for displayID: CGDirectDisplayID,
        isVirtual: Bool
    ) -> [AppBadgeModel] {
        [
            AppBadgeModel(
                title: displayTypeLabel(for: displayID),
                style: displayTypeBadgeStyle(isVirtual: isVirtual)
            )
        ]
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

@MainActor
private final class DisplayReconfigurationMonitor {
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
            Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
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
        Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
    }

    deinit {
        assert(!isRunning, "DisplayReconfigurationMonitor must be stopped before deallocation.")
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

        let monitor = Unmanaged<DisplayReconfigurationMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        Task { @MainActor in
            monitor.handleDisplayChange()
        }
    }
}

#Preview {
    ShareView()
        .environment(AppHelper(preview: true))
}
