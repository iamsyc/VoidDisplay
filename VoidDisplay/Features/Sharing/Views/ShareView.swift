//
//  ShareView.swift
//  VoidDisplay
//

import SwiftUI
import ScreenCaptureKit
import Combine
import OSLog

struct ShareView: View {
    @Environment(SharingController.self) private var sharing
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @State private var viewModel = ShareViewModel()
    @State private var displayRefreshMonitor = DebouncingDisplayReconfigurationMonitor()
    @State private var displayRefreshFallbackTask: Task<Void, Never>?
    @State private var showToolbarRefresh = false
    @Environment(\.openURL) private var openURL
    private let sharingStatsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        shareContent
            .accessibilityIdentifier("share_content_root")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                if sharing.isWebServiceRunning {
                    if showToolbarRefresh {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            viewModel.refreshDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
                        }
                    }
                    Button("Stop Service") {
                        viewModel.stopService(sharing: sharing, virtualDisplay: virtualDisplay)
                    }
                    .accessibilityIdentifier("share_stop_service_button")
                }
            }
            .onAppear {
                viewModel.refreshPermissionAndMaybeLoad(sharing: sharing, virtualDisplay: virtualDisplay)
                startDisplayRefreshMonitoring()
            }
            .onDisappear {
                viewModel.cancelInFlightDisplayLoad()
                stopDisplayRefreshMonitoring()
            }
            .onChange(of: sharing.isWebServiceRunning) { _, _ in
                viewModel.syncForCurrentState(sharing: sharing, virtualDisplay: virtualDisplay)
            }
            .onChange(of: sharing.isSharing) { _, _ in
                viewModel.syncForCurrentState(sharing: sharing, virtualDisplay: virtualDisplay)
            }
            .onReceive(sharingStatsTimer) { _ in
                guard sharing.isWebServiceRunning else { return }
                sharing.refreshSharingClientCount()
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

    private func startDisplayRefreshMonitoring() {
        let registered = displayRefreshMonitor.start {
            guard viewModel.hasScreenCapturePermission == true else { return }
            viewModel.refreshDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
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

    private func stopDisplayRefreshMonitoring() {
        displayRefreshMonitor.stop()
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

                viewModel.refreshDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
                cycle += 1
                if cycle % 5 != 0 { continue }

                let recovered = displayRefreshMonitor.start {
                    guard viewModel.hasScreenCapturePermission == true else { return }
                    viewModel.refreshDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
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
        } else if !sharing.isWebServiceRunning {
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
                        viewModel.startService(sharing: sharing, virtualDisplay: virtualDisplay)
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
                        viewModel.refreshDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
                    }
                    .accessibilityIdentifier("share_empty_refresh_button")
                }
                .padding(.horizontal, AppUI.Spacing.large)
                .padding(.top, 6)
                .accessibilityIdentifier("share_displays_empty_state")
            } else {
                ShareDisplayList(
                    displays: displays,
                    viewModel: viewModel,
                    openURLAction: openURL
                )
            }
        } else {
            VStack(spacing: AppUI.Spacing.medium) {
                Text("No screen to share")
                Button("Refresh") {
                    viewModel.refreshDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
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
                viewModel.requestScreenCapturePermission(sharing: sharing, virtualDisplay: virtualDisplay)
            },
            onRefresh: {
                viewModel.refreshPermissionAndMaybeLoad(sharing: sharing, virtualDisplay: virtualDisplay)
            },
            onRetry: (viewModel.loadErrorMessage != nil || viewModel.lastLoadError != nil) ? {
                // User-initiated retry: attempt to load the display list.
                // If permission is still missing, macOS may prompt here (expected).
                viewModel.loadDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
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
}

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    ShareView()
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}
