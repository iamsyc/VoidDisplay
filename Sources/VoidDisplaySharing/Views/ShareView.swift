import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import SwiftUI
import ScreenCaptureKit
import AppKit
import CoreGraphics

package struct ShareView: View {
    @State private var viewModel: ShareViewModel
    @State private var lifecycle: DisplayTopologyRefreshLifecycleController
    @Environment(\.openURL) private var openURL
    private let runtimeState: ShareRuntimeState
    private let catalogActions: ShareCatalogActions
    private let displayStatusProvider: ShareDisplayStatusProvider
    private let performanceMode: SharePerformanceModeBinding

    package init(
        catalogState: ScreenCaptureDisplayCatalogState,
        dependencies: ShareViewModel.Dependencies,
        runtimeState: ShareRuntimeState,
        catalogActions: ShareCatalogActions,
        displayStatusProvider: ShareDisplayStatusProvider,
        performanceMode: SharePerformanceModeBinding,
        lifecycle: DisplayTopologyRefreshLifecycleController = DisplayTopologyRefreshLifecycleController()
    ) {
        _viewModel = State(
            initialValue: ShareViewModel(
                catalogState: catalogState,
                dependencies: dependencies
            )
        )
        _lifecycle = State(initialValue: lifecycle)
        self.runtimeState = runtimeState
        self.catalogActions = catalogActions
        self.displayStatusProvider = displayStatusProvider
        self.performanceMode = performanceMode
    }

    package var body: some View {
        @Bindable var bindableViewModel = viewModel

        VStack(spacing: 0) {
            shareContent
                .accessibilityIdentifier("share_content_root")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_screen_sharing")
        .toolbar {
            if runtimeState.isWebServiceRunning {
                if lifecycle.showToolbarRefresh {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await catalogActions.forceRefresh() }
                    }
                }
                Button("Stop Service") {
                    viewModel.stopService()
                }
                .accessibilityIdentifier("share_stop_service_button")
            }
        }
        .onAppear {
            Task { await catalogActions.handleAppear() }
            lifecycle.handleAppear {
                guard viewModel.catalog.hasScreenCapturePermission == true else { return }
                Task { await catalogActions.handleTopologyChanged() }
            }
        }
        .onDisappear {
            Task { await catalogActions.handleDisappear() }
            lifecycle.handleDisappear()
        }
        .onChange(of: runtimeState.isWebServiceRunning) { _, isRunning in
            Task { await catalogActions.handleSharingServiceStateChanged(isRunning) }
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
            isWebServiceRunning: runtimeState.isWebServiceRunning,
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
                runtimeState: runtimeState,
                openURLAction: openURL,
                displayStatusProvider: displayStatusProvider
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
        let contentColumnWidth: CGFloat = 440

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
                    .frame(width: contentColumnWidth)

                VStack(spacing: AppUI.Spacing.medium) {
                    SharePerformanceModePicker(performanceMode: performanceMode)
                        .frame(width: contentColumnWidth)

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
                        .frame(width: contentColumnWidth, alignment: .center)

                        Text(viewModel.portInputErrorMessage ?? " ")
                            .font(.caption)
                            .foregroundStyle(viewModel.portInputErrorMessage == nil ? .clear : .red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.center)
                            .frame(minWidth: contentColumnWidth, maxWidth: contentColumnWidth, minHeight: 14, maxHeight: 14, alignment: .center)
                            .accessibilityIdentifier("share_port_error_text")
                    }
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
                    catalogActions.openScreenCapturePrivacySettings { url in
                        openURL(url)
                    }
                },
                onRequestPermission: {
                    Task { await catalogActions.requestPermission() }
                },
                onRefresh: {
                    Task { await catalogActions.refreshPermission() }
                },
                onRetry: (viewModel.catalog.loadErrorMessage != nil || viewModel.catalog.lastLoadError != nil) ? {
                    Task { await catalogActions.forceRefresh() }
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
                SharePerformanceModePicker(performanceMode: performanceMode)
                    .frame(maxWidth: 360)
                Button("Refresh") {
                    Task { await catalogActions.forceRefresh() }
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
    ShareView(
        catalogState: ScreenCaptureDisplayCatalogState(),
        dependencies: .noop,
        runtimeState: .inactive,
        catalogActions: .noop,
        displayStatusProvider: .none,
        performanceMode: .automatic
    )
}
