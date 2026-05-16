import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
//
//  CaptureChoose.swift
//  VoidDisplay
//
//

import SwiftUI
import ScreenCaptureKit
import AppKit
package struct IsCapturing: View {
    @State private var viewModel: CaptureChooseViewModel
    @State private var lifecycle: DisplayTopologyRefreshLifecycleController
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) private var openURL
    private let previewActions: CapturePreviewActions
    private let sharingStatusProvider: CaptureSharingStatusProvider
    private let catalogActions: CaptureCatalogActions

    package init(
        catalogState: ScreenCaptureDisplayCatalogState,
        previewActions: CapturePreviewActions,
        sharingStatusProvider: CaptureSharingStatusProvider,
        virtualDisplayStatusProvider: CaptureVirtualDisplayStatusProvider,
        catalogActions: CaptureCatalogActions,
        lifecycle: DisplayTopologyRefreshLifecycleController = DisplayTopologyRefreshLifecycleController()
    ) {
        _viewModel = State(
            initialValue: CaptureChooseViewModel(
                catalogState: catalogState,
                dependencies: .init(
                    captureActions: previewActions,
                    virtualDisplayStatusProvider: virtualDisplayStatusProvider
                )
            )
        )
        _lifecycle = State(initialValue: lifecycle)
        self.previewActions = previewActions
        self.sharingStatusProvider = sharingStatusProvider
        self.catalogActions = catalogActions
    }

    private var shouldShowActiveSessionFallback: Bool {
        guard !previewActions.sessions().isEmpty else { return false }
        if viewModel.catalog.hasScreenCapturePermission == true,
           let displays = viewModel.catalog.displays,
           !viewModel.visibleDisplays(from: displays).isEmpty {
            return false
        }
        return true
    }

    package var body: some View {
        @Bindable var bindableViewModel = viewModel

        VStack(spacing: 0) {
            catalogContent
            .safeAreaInset(edge: .top, spacing: 0) {
                if shouldShowActiveSessionFallback {
                    VStack(spacing: 0) {
                        activePreviewSessionsFallback
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                Task { await catalogActions.handleAppear() }
                guard !UITestRuntime.isEnabled else { return }
                lifecycle.handleAppear {
                    guard viewModel.catalog.hasScreenCapturePermission == true else { return }
                    Task { await catalogActions.handleTopologyChanged() }
                }
            }
            .onDisappear {
                Task { await catalogActions.handleDisappear() }
                guard !UITestRuntime.isEnabled else { return }
                lifecycle.handleDisappear()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture_choose_root")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_screen_preview")
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
    private var catalogContent: some View {
        if viewModel.catalog.hasScreenCapturePermission == false {
            screenCapturePermissionView
        } else if let displays = viewModel.catalog.displays {
            let visibleDisplays = viewModel.visibleDisplays(from: displays)
            if visibleDisplays.isEmpty {
                emptyDisplaysState
            } else {
                displayList(visibleDisplays)
            }
        } else if viewModel.catalog.isLoadingDisplays || viewModel.catalog.hasScreenCapturePermission == nil {
            loadingState
        } else {
            loadFailedState
        }
    }

    private var emptyDisplaysState: some View {
        stateContainer {
            ContentUnavailableView(
                "No watchable screen",
                systemImage: "display.trianglebadge.exclamationmark",
                description: Text("No available display can be previewed right now.")
            )
            .accessibilityIdentifier("capture_displays_empty_state")
        }
    }

    private var loadingState: some View {
        stateContainer {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("capture_loading_displays")
        }
    }

    private var loadFailedState: some View {
        stateContainer {
            VStack(spacing: 12) {
                Text("No watchable screen")
                if let loadErrorMessage = viewModel.catalog.loadErrorMessage {
                    Text(loadErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                Button("Retry") {
                    Task { await catalogActions.refreshPermission() }
                }
            }
        }
    }

    // MARK: - Display List

    private func displayList(_ displays: [SCDisplay]) -> some View {
        let gridSpacing = AppUI.List.sectionSpacing
        // Let SwiftUI choose column count from a per-card minimum width instead of a hard cutoff.
        let minimumAdaptiveCardWidth: CGFloat = 380
        return ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: minimumAdaptiveCardWidth), spacing: gridSpacing, alignment: .top)
                ],
                spacing: gridSpacing
            ) {
                ForEach(displays, id: \.self) { display in
                    captureDisplayRowComponent(display)
                }
            }
            .appListContentInsets()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: AppUI.Spacing.small + 2) {
                Divider()
                Text("If a display is set to mirror mode, only one mirrored display appears here.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppUI.Spacing.large)
            .padding(.top, AppUI.Spacing.small + 2)
            .padding(.bottom, AppUI.Spacing.medium)
        }
        .accessibilityIdentifier("capture_displays_list")
    }

    private var activePreviewSessionsFallback: some View {
        VStack(spacing: AppUI.List.sectionSpacing) {
            ForEach(previewActions.sessions()) { session in
                PreviewSessionRow(
                    session: session,
                    isSharing: sharingStatusProvider.isDisplaySharing(session.displayID)
                ) {
                    Task { await previewActions.closePreviewSession(session.id) }
                }
            }
        }
        .appListContentInsets()
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("capture_active_sessions_fallback")
    }

    private func captureDisplayRowComponent(_ display: SCDisplay) -> some View {
        let isVirtualDisplay = viewModel.isVirtualDisplay(display)
        let isPrimaryDisplay = CGDisplayIsMain(display.displayID) != 0
        let previewSession = previewActions.previewSessionForDisplayID(display.displayID)
        let isPreviewing = previewSession?.state == .active
        let isStarting = previewActions.isStartingDisplayID(display.displayID) || previewSession?.state == .starting

        return CaptureDisplayRow(
            display: display,
            displayName: viewModel.displayName(for: display),
            resolutionText: viewModel.resolutionText(for: display),
            isVirtualDisplay: isVirtualDisplay,
            isPrimaryDisplay: isPrimaryDisplay,
            isPreviewing: isPreviewing,
            isStarting: isStarting,
            isSharing: sharingStatusProvider.isDisplaySharing(display.displayID)
        ) {
            if isPreviewing, let session = previewSession {
                Task { await previewActions.closePreviewSession(session.id) }
            } else {
                Task {
                    await viewModel.startPreview(display: display) { sessionId in
                        openWindow(value: sessionId)
                    }
                }
            }
        }
    }

    // MARK: - Permission View

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
                debugItems: capturePermissionDebugItems,
                rootAccessibilityIdentifier: "capture_permission_guide",
                openSettingsButtonAccessibilityIdentifier: "capture_open_settings_button",
                requestPermissionButtonAccessibilityIdentifier: "capture_request_permission_button",
                refreshButtonAccessibilityIdentifier: "capture_refresh_button"
            )
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            .appListContentInsets()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var capturePermissionDebugItems: [(title: String, value: String)] {
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

    private func stateContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, minHeight: 200)
                .appListContentInsets()
        }
    }

}
