import VoidDisplayVirtualDisplay
import VoidDisplayCapture
import VoidDisplaySharing
import VoidDisplaySupport
import VoidDisplayObservability
import VoidDisplayFoundation
import VoidDisplayRuntime
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
    private let displayRuntime: DisplayRuntime

    @State private var hasAutoOpenedCapturePreview = false
    @State private var displayDestination: DisplayDestination = .overview

    private enum DisplayDestination: String, Hashable {
        case overview
        case virtualDisplay
        case monitor
        case lanWebView
    }

    private var displayActivityProvider: AppDisplayActivityStatusProvider {
        AppDisplayActivityStatusProvider(capture: capture, sharing: sharing)
    }

    private var displaySurfaceActions: DisplaySurfaceActions {
        let monitoringActions = CaptureUIComposition.monitoringActions(
            capture: capture,
            displayRuntime: displayRuntime
        )
        let sharingDependencies = SharingUIComposition.dependencies(
            sharing: sharing,
            virtualDisplay: virtualDisplay,
            displayRuntime: displayRuntime
        )

        return DisplaySurfaceActions(
            manageVirtualDisplay: {
                openDisplayDestination(.virtualDisplay)
            },
            openMonitor: {
                openDisplayDestination(.monitor)
            },
            stopMonitor: { displayID in
                guard let session = monitoringActions.monitoringSessionForDisplayID(displayID) else {
                    return
                }
                monitoringActions.closeMonitoringSession(session.id)
            },
            openLANWebView: {
                openDisplayDestination(.lanWebView)
            },
            stopLANWebViewSharing: { displayID in
                sharingDependencies.sharingActions.stopSharing(displayID)
            },
            stopWebService: {
                sharingDependencies.sharingActions.stopWebService()
            },
            openDiagnostics: {
                navigation.sidebarSelection = .diagnostics
            }
        )
    }

    package init(
        screenCatalogOrchestrator: ScreenCatalogOrchestrator,
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController,
        displayRuntime: DisplayRuntime
    ) {
        self.screenCatalogOrchestrator = screenCatalogOrchestrator
        self.observability = observability
        self.feedbackController = feedbackController
        self.displayRuntime = displayRuntime
    }

    package var body: some View {
        @Bindable var bindableNavigation = navigation

        NavigationSplitView {
            List(selection: $bindableNavigation.sidebarSelection) {
                Section("Display") {
                    NavigationLink(value: AppSidebarItem.screen) {
                        Label("Displays", systemImage: "display")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        showDisplaysOverview()
                    })
                    .accessibilityIdentifier("sidebar_displays")
                }

                Section(String(localized: "Diagnostics")) {
                    NavigationLink(value: AppSidebarItem.diagnostics) {
                        Label(String(localized: "Diagnostics"), systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("sidebar_diagnostics")
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
                        displayDestinationView
                            .navigationTitle(displayDestinationTitle)
                            .accessibilityIdentifier(displayDestinationAccessibilityIdentifier)
                    case .diagnostics:
                        DiagnosticsView(
                            observability: observability,
                            feedbackController: feedbackController
                        )
                            .navigationTitle(String(localized: "Health & Diagnostics"))
                            .accessibilityIdentifier("detail_diagnostics")
                    }
                }
                .id(detailIdentity)
            }
        }
        .onAppear {
            autoOpenCapturePreviewWindowIfNeeded()
        }
    }

    @ViewBuilder
    private var displayDestinationView: some View {
        switch displayDestination {
        case .overview:
            DisplaysView(
                displayRuntime: displayRuntime,
                surfaceActions: displaySurfaceActions
            )
        case .virtualDisplay:
            if UITestRuntime.isEnabled {
                VirtualDisplayView(
                    controller: virtualDisplay,
                    activityProvider: displayActivityProvider
                )
                    .accessibilityValue(Text("\(virtualDisplay.rebuildRequestCount)"))
            } else {
                VirtualDisplayView(
                    controller: virtualDisplay,
                    activityProvider: displayActivityProvider
                )
            }
        case .monitor:
            IsCapturing(
                catalogState: capture.displayCatalogState,
                monitoringActions: CaptureUIComposition.monitoringActions(
                    capture: capture,
                    displayRuntime: displayRuntime
                ),
                sharingStatusProvider: CaptureUIComposition.sharingStatusProvider(sharing: sharing),
                virtualDisplayStatusProvider: CaptureUIComposition.virtualDisplayStatusProvider(
                    virtualDisplay: virtualDisplay
                ),
                catalogActions: CaptureUIComposition.catalogActions(
                    screenCatalog: screenCatalogOrchestrator
                )
            )
        case .lanWebView:
            ShareView(
                catalogState: sharing.displayCatalogState,
                dependencies: SharingUIComposition.dependencies(
                    sharing: sharing,
                    virtualDisplay: virtualDisplay,
                    displayRuntime: displayRuntime
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
        }
    }

    private var displayDestinationTitle: LocalizedStringKey {
        switch displayDestination {
        case .overview:
            "Displays"
        case .virtualDisplay:
            "Virtual Display"
        case .monitor:
            "Monitor"
        case .lanWebView:
            "LAN Web View"
        }
    }

    private var displayDestinationAccessibilityIdentifier: String {
        switch displayDestination {
        case .overview:
            "detail_displays"
        case .virtualDisplay:
            "detail_virtual_display"
        case .monitor:
            "detail_monitor_screen"
        case .lanWebView:
            "detail_lan_web_view"
        }
    }

    private var detailIdentity: String {
        switch navigation.sidebarSelection ?? .screen {
        case .screen:
            "screen-\(displayDestination.rawValue)"
        case .diagnostics:
            "diagnostics"
        }
    }

    private func showDisplaysOverview() {
        displayDestination = .overview
        navigation.sidebarSelection = .screen
    }

    private func openDisplayDestination(_ destination: DisplayDestination) {
        displayDestination = destination
        navigation.sidebarSelection = .screen
    }

    private func autoOpenCapturePreviewWindowIfNeeded() {
        guard CapturePreviewDiagnosticsRuntime.shouldAutoOpenPreviewWindow,
              !hasAutoOpenedCapturePreview,
              let sessionID = capture.screenCaptureSessions.first?.id
        else {
            return
        }

        openDisplayDestination(.monitor)
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
        feedbackController: env.feedbackController,
        displayRuntime: env.displayRuntime
    )
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
        .environment(env.capturePerformancePreferences)
        .environment(AppNavigationController())
}
