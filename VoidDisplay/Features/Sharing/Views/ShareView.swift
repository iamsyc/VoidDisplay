//
//  ShareView.swift
//  VoidDisplay
//

import SwiftUI
import ScreenCaptureKit
import Combine
import OSLog
import AppKit
import CoreGraphics

struct ShareView: View {
    @Bindable private var sharing: SharingController
    @State private var viewModel: ShareViewModel
    @State private var displayRefreshMonitor = DebouncingDisplayReconfigurationMonitor()
    @State private var displayRefreshFallbackTask: Task<Void, Never>?
    @State private var showToolbarRefresh = false
    @State private var lastKnownDisplayTopologySignature: [CGDirectDisplayID] = []
    @Environment(\.openURL) private var openURL
    private let sharingStatsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        _sharing = Bindable(sharing)
        _viewModel = State(
            initialValue: ShareViewModel(
                catalogState: sharing.displayCatalogState,
                dependencies: .live(sharing: sharing, virtualDisplay: virtualDisplay)
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            shareContent
                .accessibilityIdentifier("share_content_root")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_screen_sharing")
        .toolbar {
            if sharing.isWebServiceRunning {
                if showToolbarRefresh {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        viewModel.refreshDisplays()
                    }
                }
                Button("Stop Service") {
                    viewModel.stopService()
                }
                .accessibilityIdentifier("share_stop_service_button")
            }
        }
        .onAppear {
            viewModel.refreshPermissionAndMaybeLoad()
            startDisplayRefreshMonitoring()
        }
        .onDisappear {
            viewModel.cancelInFlightDisplayLoad()
            stopDisplayRefreshMonitoring()
        }
        .onChange(of: sharing.isWebServiceRunning) { _, _ in
            viewModel.syncForCurrentState()
        }
        .onChange(of: sharing.isSharing) { _, _ in
            viewModel.syncForCurrentState()
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
        lastKnownDisplayTopologySignature = displayTopologySignature()
        let registered = displayRefreshMonitor.start {
            guard viewModel.catalog.hasScreenCapturePermission == true else { return }
            viewModel.refreshDisplaysBackgroundSafe()
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
        lastKnownDisplayTopologySignature = displayTopologySignature()
        displayRefreshFallbackTask = Task { @MainActor in
            var cycle: Int = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard viewModel.catalog.hasScreenCapturePermission == true else { continue }

                refreshDisplaysIfTopologyChanged()
                cycle += 1
                if cycle % 5 != 0 { continue }

                let recovered = displayRefreshMonitor.start {
                    guard viewModel.catalog.hasScreenCapturePermission == true else { return }
                    viewModel.refreshDisplaysBackgroundSafe()
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

    private func displayTopologySignature() -> [CGDirectDisplayID] {
        NSScreen.screens
            .compactMap(\.cgDirectDisplayID)
            .sorted()
    }

    private func refreshDisplaysIfTopologyChanged() {
        let signature = displayTopologySignature()
        guard signature != lastKnownDisplayTopologySignature else { return }
        lastKnownDisplayTopologySignature = signature
        viewModel.refreshDisplaysBackgroundSafe()
    }

    private func stopDisplayRefreshFallbackPolling() {
        displayRefreshFallbackTask?.cancel()
        displayRefreshFallbackTask = nil
    }

    @ViewBuilder
    private var shareContent: some View {
        if viewModel.catalog.hasScreenCapturePermission == false {
            screenCapturePermissionView
        } else if viewModel.catalog.hasScreenCapturePermission == nil {
            permissionLoadingState
        } else if !sharing.isWebServiceRunning {
            serviceStoppedState
        } else if let displays = viewModel.catalog.displays {
            let visibleDisplays = viewModel.visibleDisplays(from: displays)
            if visibleDisplays.isEmpty {
                shareEmptyState
            } else {
                ShareDisplayList(
                    displays: visibleDisplays,
                    viewModel: viewModel,
                    openURLAction: openURL
                )
            }
        } else if viewModel.catalog.isLoadingDisplays {
            displaysLoadingState
        } else {
            shareEmptyState
        }
    }

    private var permissionLoadingState: some View {
        stateContainer {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .foregroundColor(.secondary)
            }
            .accessibilityIdentifier("share_loading_permission")
        }
    }

    private var serviceStoppedState: some View {
        stateContainer {
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

                VStack(spacing: 4) {
                    HStack(spacing: AppUI.Spacing.small) {
                        Text("Port")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(
                            "8089",
                            text: Binding(
                                get: { viewModel.servicePortInput },
                                set: { viewModel.updateServicePortInput($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                        .accessibilityIdentifier("share_port_input")
                    }

                    Text(viewModel.portInputErrorMessage ?? " ")
                        .font(.caption2)
                        .foregroundStyle(viewModel.portInputErrorMessage == nil ? .clear : .red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360, minHeight: 14, maxHeight: 14, alignment: .center)
                        .accessibilityIdentifier("share_port_error_text")
                }

                Button("Start Service") {
                    viewModel.startService()
                }
                .appActionButtonStyle(variant: .primary)
                .controlSize(.large)
                .disabled(viewModel.isStartingService)
                .accessibilityIdentifier("share_start_service_button")
            }
        }
    }

    private var displaysLoadingState: some View {
        stateContainer {
            ProgressView("Loading displays…")
                .frame(maxWidth: .infinity, minHeight: 200)
                .accessibilityIdentifier("share_loading_displays")
        }
    }

    private var screenCapturePermissionView: some View {
        ScreenCapturePermissionGuideView(
            loadErrorMessage: viewModel.catalog.loadErrorMessage,
            onOpenSettings: {
                viewModel.openScreenCapturePrivacySettings { url in
                    openURL(url)
                }
            },
            onRequestPermission: {
                viewModel.requestScreenCapturePermission()
            },
            onRefresh: {
                viewModel.refreshPermissionAndMaybeLoad()
            },
            onRetry: (viewModel.catalog.loadErrorMessage != nil || viewModel.catalog.lastLoadError != nil) ? {
                // User-initiated retry: attempt to load the display list.
                // If permission is still missing, macOS may prompt here (expected).
                viewModel.loadDisplays()
            } : nil,
            isDebugInfoExpanded: Binding(
                get: { viewModel.catalog.showDebugInfo },
                set: { viewModel.catalog.showDebugInfo = $0 }
            ),
            debugItems: sharingPermissionDebugItems,
            rootAccessibilityIdentifier: "share_permission_guide",
            openSettingsButtonAccessibilityIdentifier: "share_open_settings_button",
            requestPermissionButtonAccessibilityIdentifier: "share_request_permission_button",
            refreshButtonAccessibilityIdentifier: "share_refresh_button"
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share_permission_guide")
    }

    private var shareEmptyState: some View {
        stateContainer {
            VStack(spacing: AppUI.Spacing.medium) {
                Text("No screen to share")
                Button("Refresh") {
                    viewModel.refreshDisplays()
                }
                .appActionButtonStyle(variant: .default)
                .accessibilityIdentifier("share_empty_refresh_button")
            }
            .accessibilityIdentifier("share_displays_empty_state")
        }
    }

    private func stateContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, minHeight: 200)
                .appListContentInsets()
        }
    }

    private var sharingPermissionDebugItems: [(title: String, value: String)] {
        var items: [(title: String, value: String)] = [
            (String(localized: "Bundle ID"), Bundle.main.bundleIdentifier ?? "-"),
            (String(localized: "App Path"), Bundle.main.bundleURL.path),
            (
                String(localized: "Preflight Permission"),
                (viewModel.catalog.lastPreflightPermission ?? viewModel.catalog.hasScreenCapturePermission)
                    .map { $0 ? "true" : "false" } ?? "-"
            ),
            (
                String(localized: "Request Permission Result"),
                viewModel.catalog.lastRequestPermission.map { $0 ? "true" : "false" } ?? "-"
            )
        ]

        if let lastLoadError = viewModel.catalog.lastLoadError {
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
    ShareView(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}
