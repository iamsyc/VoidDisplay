//
//  HomeView.swift
//  VoidDisplay
//
//

import SwiftUI

struct HomeView: View {
    @Environment(AppNavigationController.self) private var navigation
    @Environment(CaptureController.self) private var capture
    @Environment(SharingController.self) private var sharing
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @Environment(\.openWindow) private var openWindow
    private let screenCatalogOrchestrator: ScreenCatalogOrchestrator
    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController

    @State private var hasAutoOpenedCapturePreview = false

    init(
        screenCatalogOrchestrator: ScreenCatalogOrchestrator,
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController
    ) {
        self.screenCatalogOrchestrator = screenCatalogOrchestrator
        self.observability = observability
        self.feedbackController = feedbackController
    }

    var body: some View {
        @Bindable var bindableNavigation = navigation

        NavigationSplitView {
            List(selection: $bindableNavigation.sidebarSelection) {
                Section("Display") {
                    NavigationLink(value: AppSidebarItem.screen) {
                        Label("Displays", systemImage: "display")
                    }
                        .accessibilityIdentifier("sidebar_screen")
                    NavigationLink(value: AppSidebarItem.virtualDisplay) {
                        Label("Virtual Displays", systemImage: "display.2")
                    }
                        .accessibilityIdentifier("sidebar_virtual_display")
                    NavigationLink(value: AppSidebarItem.monitorScreen) {
                        Label("Screen Monitoring", systemImage: "dot.scope.display")
                    }
                        .accessibilityIdentifier("sidebar_monitor_screen")
                }

                Section("Sharing") {
                    NavigationLink(value: AppSidebarItem.screenSharing) {
                        Label("Screen Sharing", systemImage: "display")
                    }
                        .accessibilityIdentifier("sidebar_screen_sharing")
                }

                Section(String(localized: "Support")) {
                    NavigationLink(value: AppSidebarItem.supportCenter) {
                        Label(String(localized: "Support Center"), systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("sidebar_support_center")
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("home_sidebar")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            NavigationStack {
                Group {
                    switch bindableNavigation.sidebarSelection ?? .screen {
                    case .screen:
                        DisplaysView()
                            .navigationTitle("Displays")
                            .accessibilityIdentifier("detail_screen")
                    case .virtualDisplay:
                        if UITestRuntime.isEnabled {
                            VirtualDisplayView(controller: virtualDisplay)
                                .navigationTitle("Virtual Displays")
                                .accessibilityIdentifier("detail_virtual_display")
                                .accessibilityValue(Text("\(virtualDisplay.rebuildRequestCount)"))
                        } else {
                            VirtualDisplayView(controller: virtualDisplay)
                                .navigationTitle("Virtual Displays")
                                .accessibilityIdentifier("detail_virtual_display")
                        }
                    case .monitorScreen:
                        IsCapturing(
                            capture: capture,
                            virtualDisplay: virtualDisplay,
                            screenCatalogOrchestrator: screenCatalogOrchestrator
                        )
                            .navigationTitle("Screen Monitoring")
                            .accessibilityIdentifier("detail_monitor_screen")
                    case .screenSharing:
                        ShareView(
                            sharing: sharing,
                            virtualDisplay: virtualDisplay,
                            screenCatalogOrchestrator: screenCatalogOrchestrator
                        )
                            .navigationTitle("Screen Sharing")
                            .accessibilityIdentifier("detail_screen_sharing")
                    case .supportCenter:
                        SupportCenterView(
                            observability: observability,
                            feedbackController: feedbackController
                        )
                            .navigationTitle(String(localized: "Support Center"))
                            .accessibilityIdentifier("detail_support_center")
                    }
                }
                .id(bindableNavigation.sidebarSelection ?? .screen)
            }
        }
        .onAppear {
            autoOpenCapturePreviewWindowIfNeeded()
        }
    }

    private func autoOpenCapturePreviewWindowIfNeeded() {
        guard CapturePreviewDiagnosticsRuntime.shouldAutoOpenPreviewWindow,
              !hasAutoOpenedCapturePreview,
              let sessionID = capture.screenCaptureSessions.first?.id
        else {
            return
        }

        navigation.sidebarSelection = .monitorScreen
        openWindow(value: sessionID)
        hasAutoOpenedCapturePreview = true
    }
}

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    HomeView(
        screenCatalogOrchestrator: env.screenCatalog,
        observability: env.observability,
        feedbackController: env.feedbackController
    )
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
        .environment(AppNavigationController())
}
