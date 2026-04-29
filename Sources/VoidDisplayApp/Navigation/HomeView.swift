import VoidDisplayVirtualDisplay
import VoidDisplayCapture
import VoidDisplaySharing
import VoidDisplaySupport
import VoidDisplayObservability
import VoidDisplayFoundation
import CoreGraphics
//
//  HomeView.swift
//  VoidDisplay
//
//

import SwiftUI
package struct HomeView: View {
    @Environment(AppNavigationController.self) private var navigation
    @Environment(CaptureController.self) private var capture
    @Environment(SharingController.self) private var sharing
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @Environment(CapturePerformancePreferences.self) private var capturePerformancePreferences
    @Environment(\.openWindow) private var openWindow
    private let screenCatalogOrchestrator: ScreenCatalogOrchestrator
    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController

    @State private var hasAutoOpenedCapturePreview = false

    private var displayActivityProvider: AppDisplayActivityStatusProvider {
        AppDisplayActivityStatusProvider(capture: capture, sharing: sharing)
    }

    package init(
        screenCatalogOrchestrator: ScreenCatalogOrchestrator,
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController
    ) {
        self.screenCatalogOrchestrator = screenCatalogOrchestrator
        self.observability = observability
        self.feedbackController = feedbackController
    }

    package var body: some View {
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
                        DisplaysView(activityProvider: displayActivityProvider)
                            .navigationTitle("Displays")
                            .accessibilityIdentifier("detail_screen")
                    case .virtualDisplay:
                        if UITestRuntime.isEnabled {
                            VirtualDisplayView(
                                controller: virtualDisplay,
                                activityProvider: displayActivityProvider
                            )
                                .navigationTitle("Virtual Displays")
                                .accessibilityIdentifier("detail_virtual_display")
                                .accessibilityValue(Text("\(virtualDisplay.rebuildRequestCount)"))
                        } else {
                            VirtualDisplayView(
                                controller: virtualDisplay,
                                activityProvider: displayActivityProvider
                            )
                                .navigationTitle("Virtual Displays")
                                .accessibilityIdentifier("detail_virtual_display")
                        }
                    case .monitorScreen:
                        IsCapturing(
                            catalogState: capture.displayCatalogState,
                            monitoringActions: CaptureUIComposition.monitoringActions(capture: capture),
                            sharingStatusProvider: CaptureUIComposition.sharingStatusProvider(sharing: sharing),
                            virtualDisplayStatusProvider: CaptureUIComposition.virtualDisplayStatusProvider(
                                virtualDisplay: virtualDisplay
                            ),
                            catalogActions: CaptureUIComposition.catalogActions(
                                screenCatalog: screenCatalogOrchestrator
                            )
                        )
                            .navigationTitle("Screen Monitoring")
                            .accessibilityIdentifier("detail_monitor_screen")
                    case .screenSharing:
                        ShareView(
                            catalogState: sharing.displayCatalogState,
                            dependencies: SharingUIComposition.dependencies(
                                sharing: sharing,
                                virtualDisplay: virtualDisplay
                            ),
                            runtimeState: SharingUIComposition.runtimeState(
                                sharing: sharing
                            ),
                            catalogActions: SharingUIComposition.catalogActions(
                                screenCatalog: screenCatalogOrchestrator
                            ),
                            displayStatusProvider: SharingUIComposition.displayStatusProvider(
                                capture: capture,
                                virtualDisplay: virtualDisplay
                            ),
                            performanceMode: SharingUIComposition.performanceModeBinding(
                                capturePerformancePreferences: capturePerformancePreferences
                            )
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

private struct AppDisplayActivityStatusProvider: DisplayActivityStatusProviding {
    let capture: CaptureController
    let sharing: SharingController

    @MainActor
    func activityStatus(for displayID: CGDirectDisplayID) -> DisplayActivityStatus {
        DisplayActivityStatus(
            isMonitoring: capture.screenCaptureSessions.contains { $0.displayID == displayID },
            isSharing: sharing.isDisplaySharing(displayID: displayID)
        )
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
        .environment(env.capturePerformancePreferences)
        .environment(AppNavigationController())
}
