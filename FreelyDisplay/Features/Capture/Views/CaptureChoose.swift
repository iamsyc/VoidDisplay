//
//  CaptureChoose.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/5.
//

import SwiftUI
import ScreenCaptureKit
import Cocoa
import CoreGraphics

struct IsCapturing: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State private var viewModel = CaptureChooseViewModel()
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) private var openURL

    private var shouldShowActiveSessionFallback: Bool {
        guard !appHelper.screenCaptureSessions.isEmpty else { return false }
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
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .appScreenBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture_choose_root")
    }

    // MARK: - Display List

    private func displayList(_ displays: [SCDisplay]) -> some View {
        GeometryReader { geometry in
            let useGrid = geometry.size.width > 680
            ScrollView {
                if useGrid {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppUI.Spacing.small) {
                        ForEach(displays, id: \.self) { display in
                            captureDisplayRow(display)
                        }
                    }
                    .padding(.horizontal, AppUI.List.listHorizontalInset)
                    .padding(.top, AppUI.Spacing.small + 2)
                } else {
                    LazyVStack(spacing: AppUI.List.listVerticalInset * 2) {
                        ForEach(displays, id: \.self) { display in
                            captureDisplayRow(display)
                        }
                    }
                    .padding(.horizontal, AppUI.List.listHorizontalInset)
                    .padding(.top, AppUI.Spacing.small + 2)
                }
            }
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
                ForEach(appHelper.screenCaptureSessions) { session in
                    monitoringSessionRow(session)
                }
            }
            .padding(.horizontal, AppUI.List.listHorizontalInset)
            .padding(.top, AppUI.Spacing.small + 2)
            .padding(.bottom, AppUI.Spacing.small)
        }
        .frame(maxHeight: 260)
        .accessibilityIdentifier("capture_active_sessions_fallback")
    }

    // MARK: - Display Row

    private func captureDisplayRow(_ display: SCDisplay) -> some View {
        let isVirtualDisplay = viewModel.isVirtualDisplay(display, appHelper: appHelper)
        let isPrimaryDisplay = CGDisplayIsMain(display.displayID) != 0
        let monitoringSession = appHelper.screenCaptureSessions.first(where: { $0.displayID == display.displayID })
        let isMonitoring = monitoringSession?.state == .active
        let isStarting = viewModel.startingDisplayIDs.contains(display.displayID) || monitoringSession?.state == .starting

        let model = AppListRowModel(
            id: String(display.displayID),
            title: viewModel.displayName(for: display),
            subtitle: viewModel.resolutionText(for: display),
            status: AppRowStatus(
                title: isMonitoring
                    ? String(localized: "Monitoring")
                    : String(localized: "Not Monitoring"),
                tint: isMonitoring ? .green : .gray
            ),
            metaBadges: displayBadges(for: display, isVirtualDisplay: isVirtualDisplay),
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
            monitorActionButton(
                display: display,
                monitoringSession: monitoringSession,
                isMonitoring: isMonitoring,
                isStarting: isStarting
            )
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private func monitorActionButton(
        display: SCDisplay,
        monitoringSession: AppHelper.ScreenMonitoringSession?,
        isMonitoring: Bool,
        isStarting: Bool
    ) -> some View {
        Button {
            guard !isStarting else { return }
            if isMonitoring, let session = monitoringSession {
                appHelper.removeMonitoringSession(id: session.id)
            } else {
                Task {
                    await viewModel.startMonitoring(
                        display: display,
                        appHelper: appHelper
                    ) { sessionId in
                        openWindow(value: sessionId)
                    }
                }
            }
        } label: {
            if isStarting {
                ProgressView()
                    .controlSize(.small)
            } else if isMonitoring {
                Label(String(localized: "Stop Monitoring"), systemImage: "stop.fill")
            } else {
                Label(String(localized: "Monitor Display"), systemImage: "play.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isMonitoring ? .red : .accentColor)
        .disabled(isStarting)
        .accessibilityIdentifier("capture_monitor_toggle_\(display.displayID)")
    }

    private func monitoringSessionRow(_ session: AppHelper.ScreenMonitoringSession) -> some View {
        let isStarting = session.state == .starting
        let model = AppListRowModel(
            id: session.id.uuidString,
            title: session.displayName,
            subtitle: session.resolutionText,
            status: AppRowStatus(
                title: isStarting ? String(localized: "Starting") : String(localized: "Monitoring"),
                tint: isStarting ? .orange : .green
            ),
            metaBadges: [
                AppBadgeModel(
                    title: monitoringSessionDisplayTypeLabel(session.isVirtualDisplay),
                    style: session.isVirtualDisplay
                        ? .roundedTag(tint: .blue)
                        : .roundedTag(tint: .gray)
                )
            ],
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: nil
        )

        return AppListRowCard(model: model) {
            Button(role: .destructive) {
                appHelper.removeMonitoringSession(id: session.id)
            } label: {
                Label(
                    isStarting ? String(localized: "Cancel Starting") : String(localized: "Stop Monitoring"),
                    systemImage: "stop.fill"
                )
            }
            .buttonStyle(.bordered)
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

    // MARK: - Helpers

    private func monitorDisplayTypeLabel(for display: SCDisplay) -> String {
        if viewModel.isVirtualDisplay(display, appHelper: appHelper) {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }

    private func displayBadges(for display: SCDisplay, isVirtualDisplay: Bool) -> [AppBadgeModel] {
        let badges: [AppBadgeModel] = [
            AppBadgeModel(
                title: monitorDisplayTypeLabel(for: display),
                style: isVirtualDisplay
                    ? .roundedTag(tint: .blue)
                    : .roundedTag(tint: .gray)
            )
        ]
        return badges
    }

    private func monitoringSessionDisplayTypeLabel(_ isVirtualDisplay: Bool) -> String {
        if isVirtualDisplay {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }
}

#Preview {
    IsCapturing()
        .environment(AppHelper(preview: true))
}
