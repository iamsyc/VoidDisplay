//
//  CaptureChoose.swift
//  VoidDisplay
//
//

import SwiftUI
import ScreenCaptureKit
import AppKit

struct IsCapturing: View {
    @Bindable private var capture: CaptureController
    @State private var viewModel: CaptureChooseViewModel
    @Environment(SharingController.self) private var sharing
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) private var openURL

    init(
        capture: CaptureController,
        virtualDisplay: VirtualDisplayController
    ) {
        _capture = Bindable(capture)
        _viewModel = State(
            initialValue: CaptureChooseViewModel(
                catalogState: capture.displayCatalogState,
                dependencies: .live(capture: capture, virtualDisplay: virtualDisplay)
            )
        )
    }

    private var shouldShowActiveSessionFallback: Bool {
        guard !capture.screenCaptureSessions.isEmpty else { return false }
        if viewModel.catalog.hasScreenCapturePermission == true,
           let displays = viewModel.catalog.displays,
           !viewModel.visibleDisplays(from: displays).isEmpty {
            return false
        }
        return true
    }

    var body: some View {
        @Bindable var bindableViewModel = viewModel

        VStack(spacing: 0) {
            catalogContent
            .safeAreaInset(edge: .top, spacing: 0) {
                if shouldShowActiveSessionFallback {
                    VStack(spacing: 0) {
                        activeMonitoringSessionsFallback
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewModel.refreshPermissionAndMaybeLoad()
            }
            .onDisappear {
                viewModel.cancelInFlightDisplayLoad()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                viewModel.refreshDisplaysBackgroundSafe()
            }
            .appScreenBackground()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture_choose_root")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_monitor_screen")
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
                description: Text("No available display can be monitored right now.")
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
                    viewModel.refreshPermissionAndMaybeLoad()
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
                Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
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

    private var activeMonitoringSessionsFallback: some View {
        ScrollView {
            LazyVStack(spacing: AppUI.List.sectionSpacing) {
                ForEach(capture.screenCaptureSessions) { session in
                    MonitoringSessionRow(
                        session: session,
                        isSharing: sharing.isDisplaySharing(displayID: session.displayID)
                    ) {
                        capture.removeMonitoringSession(id: session.id)
                    }
                }
            }
            .appListContentInsets()
        }
        .frame(maxHeight: 260)
        .accessibilityIdentifier("capture_active_sessions_fallback")
    }

    private func captureDisplayRowComponent(_ display: SCDisplay) -> some View {
        let isVirtualDisplay = viewModel.isVirtualDisplay(display)
        let isPrimaryDisplay = CGDisplayIsMain(display.displayID) != 0
        let monitoringSession = capture.screenCaptureSessions.first(where: { $0.displayID == display.displayID })
        let isMonitoring = monitoringSession?.state == .active
        let isStarting = viewModel.startingDisplayIDs.contains(display.displayID) || monitoringSession?.state == .starting

        return CaptureDisplayRow(
            display: display,
            displayName: viewModel.displayName(for: display),
            resolutionText: viewModel.resolutionText(for: display),
            isVirtualDisplay: isVirtualDisplay,
            isPrimaryDisplay: isPrimaryDisplay,
            isMonitoring: isMonitoring,
            isStarting: isStarting,
            isSharing: sharing.isDisplaySharing(displayID: display.displayID)
        ) {
            if isMonitoring, let session = monitoringSession {
                capture.removeMonitoringSession(id: session.id)
            } else {
                Task {
                    await viewModel.startMonitoring(display: display) { sessionId in
                        openWindow(value: sessionId)
                    }
                }
            }
        }
    }

    // MARK: - Permission View

    private var screenCapturePermissionView: some View {
        @Bindable var bindableCatalog = viewModel.catalog

        return ScreenCapturePermissionGuideView(
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
                viewModel.loadDisplays()
            } : nil,
            isDebugInfoExpanded: $bindableCatalog.showDebugInfo,
            debugItems: capturePermissionDebugItems,
            rootAccessibilityIdentifier: "capture_permission_guide",
            openSettingsButtonAccessibilityIdentifier: "capture_open_settings_button",
            requestPermissionButtonAccessibilityIdentifier: "capture_request_permission_button",
            refreshButtonAccessibilityIdentifier: "capture_refresh_button"
        )
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

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    IsCapturing(capture: env.capture, virtualDisplay: env.virtualDisplay)
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}
