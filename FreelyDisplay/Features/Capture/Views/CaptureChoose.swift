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

struct CaptureChoose: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State private var viewModel = CaptureChooseViewModel()
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) private var openURL

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
                    List(displays, id: \.self) { display in
                        captureDisplayRow(display)
                            .appListRowStyle()
                    }
                    .accessibilityIdentifier("capture_displays_list")
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Spacer()
                            .frame(height: AppUI.Spacing.small + 2)
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
        .onAppear {
            viewModel.refreshPermissionAndMaybeLoad()
        }
        .appScreenBackground()
        .accessibilityIdentifier("capture_choose_root")
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
                viewModel.requestScreenCapturePermission()
            },
            onRefresh: {
                viewModel.refreshPermissionAndMaybeLoad()
            },
            onRetry: (viewModel.loadErrorMessage != nil || viewModel.lastLoadError != nil) ? {
                // User-initiated retry: attempt to load the display list.
                // If permission is still missing, macOS may prompt here (expected).
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

    private func captureDisplayRow(_ display: SCDisplay) -> some View {
        let isVirtualDisplay = viewModel.isVirtualDisplay(display, appHelper: appHelper)
        let model = AppListRowModel(
            id: String(display.displayID),
            title: viewModel.displayName(for: display),
            subtitle: viewModel.resolutionText(for: display),
            status: nil,
            metaBadges: displayBadges(for: display, isVirtualDisplay: isVirtualDisplay),
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: nil
        )
        return AppListRowCard(model: model) {
            Button("Monitor Display") {
                Task {
                    await viewModel.startMonitoring(
                        display: display,
                        appHelper: appHelper
                    ) { sessionId in
                        openWindow(value: sessionId)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func monitorDisplayTypeLabel(for display: SCDisplay) -> String {
        if viewModel.isVirtualDisplay(display, appHelper: appHelper) {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }

    private func displayBadges(for display: SCDisplay, isVirtualDisplay: Bool) -> [AppBadgeModel] {
        var badges: [AppBadgeModel] = [
            AppBadgeModel(
                title: monitorDisplayTypeLabel(for: display),
                style: isVirtualDisplay ? .accent(.blue) : .neutral
            )
        ]
        if CGDisplayIsMain(display.displayID) != 0 {
            badges.insert(AppBadgeModel(title: String(localized: "Primary Display"), style: .accent(.green)), at: 0)
        }
        return badges
    }
}

struct IsCapturing: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State var showAddView = false

    var body: some View {
        Group {
            if !appHelper.screenCaptureSessions.isEmpty {
                List(appHelper.screenCaptureSessions) { session in
                    monitoringSessionRow(session)
                        .appListRowStyle()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView(
                    "No Listening Windows",
                    systemImage: "dot.scope.display",
                    description: Text("Click + to start a new monitoring window.")
                )
            }
        }
        .toolbar {
            ToolbarItem(content: {
                Button(action: {
                    showAddView = true
                }) {
                    Label("Listening window", systemImage: "plus")
                }
                .accessibilityIdentifier("monitoring_add_button")
                .popover(isPresented: $showAddView, content: {
                    CaptureChoose()
                        .frame(width: 500, height: 400)
                })
            })
        }
        .appScreenBackground()
    }

    private func monitoringSessionRow(_ session: AppHelper.ScreenMonitoringSession) -> some View {
        let model = AppListRowModel(
            id: session.id.uuidString,
            title: session.displayName,
            subtitle: session.resolutionText,
            status: nil,
            metaBadges: [
                AppBadgeModel(
                    title: monitoringSessionDisplayTypeLabel(session.isVirtualDisplay),
                    style: session.isVirtualDisplay ? .accent(.blue) : .neutral
                ),
                AppBadgeModel(title: String(localized: "Active"), style: .accent(.green))
            ],
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: nil
        )
        return AppListRowCard(model: model) {
            Button(role: .destructive) {
                appHelper.removeMonitoringSession(id: session.id)
            } label: {
                Label("Stop Monitoring", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    private func monitoringSessionDisplayTypeLabel(_ isVirtualDisplay: Bool) -> String {
        if isVirtualDisplay {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }
}

#Preview {
    CaptureChoose()
        .environment(AppHelper(preview: true))
}
