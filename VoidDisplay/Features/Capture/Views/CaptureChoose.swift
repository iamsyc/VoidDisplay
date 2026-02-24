//
//  CaptureChoose.swift
//  VoidDisplay
//
//

import SwiftUI
import ScreenCaptureKit

struct IsCapturing: View {
    @Environment(CaptureController.self) private var capture
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @State private var viewModel = CaptureChooseViewModel()
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) private var openURL

    private var shouldShowActiveSessionFallback: Bool {
        guard !capture.screenCaptureSessions.isEmpty else { return false }
        if viewModel.hasScreenCapturePermission == true, let displays = viewModel.displays, !displays.isEmpty {
            return false
        }
        return true
    }

    var body: some View {
        Group {
            if viewModel.hasScreenCapturePermission == false {
                screenCapturePermissionView
            } else if let displays = viewModel.displays {
                if displays.isEmpty {
                    ContentUnavailableView(
                        "No watchable screen",
                        systemImage: "display.trianglebadge.exclamationmark",
                        description: Text("No available display can be monitored right now.")
                    )
                    .accessibilityIdentifier("capture_displays_empty_state")
                } else {
                    displayList(displays)
                }
            } else if viewModel.isLoadingDisplays || viewModel.hasScreenCapturePermission == nil {
                ScrollView {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        Text("No watchable screen")
                        if let loadErrorMessage = viewModel.loadErrorMessage {
                            Text(loadErrorMessage)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                        }
                        Button("Retry") {
                            viewModel.refreshPermissionAndMaybeLoad()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
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
        .appScreenBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture_choose_root")
    }

    // MARK: - Display List

    private func displayList(_ displays: [SCDisplay]) -> some View {
        let gridSpacing = AppUI.Spacing.small
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
            .padding(.horizontal, AppUI.List.listHorizontalInset)
            .padding(.top, AppUI.Spacing.small + 2)
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
            LazyVStack(spacing: AppUI.Spacing.small) {
                ForEach(capture.screenCaptureSessions) { session in
                    MonitoringSessionRow(session: session) {
                        capture.removeMonitoringSession(id: session.id)
                    }
                }
            }
            .padding(.horizontal, AppUI.List.listHorizontalInset)
            .padding(.top, AppUI.Spacing.small + 2)
            .padding(.bottom, AppUI.Spacing.small)
        }
        .frame(maxHeight: 260)
        .accessibilityIdentifier("capture_active_sessions_fallback")
    }

    private func captureDisplayRowComponent(_ display: SCDisplay) -> some View {
        let isVirtualDisplay = viewModel.isVirtualDisplay(display, virtualDisplay: virtualDisplay)
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
            isStarting: isStarting
        ) {
            if isMonitoring, let session = monitoringSession {
                capture.removeMonitoringSession(id: session.id)
            } else {
                Task {
                    await viewModel.startMonitoring(
                        display: display,
                        capture: capture,
                        virtualDisplay: virtualDisplay
                    ) { sessionId in
                        openWindow(value: sessionId)
                    }
                }
            }
        }
    }

    // MARK: - Permission View

    private var screenCapturePermissionView: some View {
        ScreenCapturePermissionGuideView(
            loadErrorMessage: viewModel.loadErrorMessage,
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
            onRetry: (viewModel.loadErrorMessage != nil || viewModel.lastLoadError != nil) ? {
                viewModel.loadDisplays()
            } : nil,
            isDebugInfoExpanded: $viewModel.showDebugInfo,
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
    IsCapturing()
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}
