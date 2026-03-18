//
//  ShareView.swift
//  VoidDisplay
//

import SwiftUI
import ScreenCaptureKit
import Combine
import AppKit
import CoreGraphics

struct ShareView: View {
    @Bindable private var sharing: SharingController
    @State private var viewModel: ShareViewModel
    @State private var lifecycle: ShareViewLifecycleController
    @Environment(\.openURL) private var openURL
    private let sharingStatsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        lifecycle: ShareViewLifecycleController = ShareViewLifecycleController()
    ) {
        _sharing = Bindable(sharing)
        _viewModel = State(
            initialValue: ShareViewModel(
                catalogState: sharing.displayCatalogState,
                dependencies: .live(sharing: sharing, virtualDisplay: virtualDisplay)
            )
        )
        _lifecycle = State(initialValue: lifecycle)
    }

    var body: some View {
        @Bindable var bindableViewModel = viewModel

        VStack(spacing: 0) {
            shareContent
                .accessibilityIdentifier("share_content_root")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_screen_sharing")
        .toolbar {
            if sharing.isWebServiceRunning {
                if lifecycle.showToolbarRefresh {
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
            lifecycle.handleAppear(viewModel: viewModel)
        }
        .onDisappear {
            lifecycle.handleDisappear(viewModel: viewModel)
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
        .alert(item: $bindableViewModel.userFacingAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    viewModel.dismissAlert()
                }
            )
        }
    }

    @ViewBuilder
    private var shareContent: some View {
        let displays = viewModel.catalog.displays
        let visibleDisplays = displays.map(viewModel.visibleDisplays(from:)) ?? []
        switch ShareViewContentResolver.resolve(
            catalog: viewModel.catalog,
            isWebServiceRunning: sharing.isWebServiceRunning,
            visibleDisplayCount: visibleDisplays.count
        ) {
        case .permissionGuide:
            screenCapturePermissionView
        case .permissionLoading:
            permissionLoadingState
        case .serviceStopped:
            serviceStoppedState
        case .displaysList:
            ShareDisplayList(
                displays: visibleDisplays,
                viewModel: viewModel,
                openURLAction: openURL
            )
        case .displaysLoading:
            displaysLoadingState
        case .empty:
            shareEmptyState
        }
    }

    private var permissionLoadingState: some View {
        stateContainer {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("share_loading_permission")
        }
    }

    private var serviceStoppedState: some View {
        @Bindable var bindableViewModel = viewModel

        return stateContainer {
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
                        TextField("8089", text: $bindableViewModel.servicePortInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 84)
                            .accessibilityIdentifier("share_port_input")
                    }

                    Text(viewModel.portInputErrorMessage ?? " ")
                        .font(.caption)
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
        @Bindable var bindableCatalog = viewModel.catalog

        return ScrollView {
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
                isDebugInfoExpanded: $bindableCatalog.showDebugInfo,
                debugItems: sharingPermissionDebugItems,
                rootAccessibilityIdentifier: "share_permission_guide",
                openSettingsButtonAccessibilityIdentifier: "share_open_settings_button",
                requestPermissionButtonAccessibilityIdentifier: "share_request_permission_button",
                refreshButtonAccessibilityIdentifier: "share_refresh_button"
            )
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            .appListContentInsets()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
