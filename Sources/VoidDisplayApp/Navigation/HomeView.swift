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
    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController
    private let displayRuntime: DisplayRuntime
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    @State private var hasAutoOpenedCapturePreview = false
    @State private var displayDestination: DisplayDestination = .overview
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private enum DisplayDestination: String, Hashable {
        case overview
        case virtualDisplay
        case preview
        case lanWebView
    }

    private var displayActivityProvider: AppDisplayActivityStatusProvider {
        AppDisplayActivityStatusProvider(capture: capture, sharing: sharing)
    }

    private var displaySurfaceActions: DisplaySurfaceActions {
        let previewActions = CaptureUIComposition.previewActions(
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
            openPreview: {
                openDisplayDestination(.preview)
            },
            stopPreview: { displayID in
                guard let session = previewActions.previewSessionForDisplayID(displayID) else {
                    return
                }
                previewActions.closePreviewSession(session.id)
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
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController,
        displayRuntime: DisplayRuntime,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void
    ) {
        self.observability = observability
        self.feedbackController = feedbackController
        self.displayRuntime = displayRuntime
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
    }

    package var body: some View {
        @Bindable var bindableNavigation = navigation

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $bindableNavigation.sidebarSelection) {
                Section("Display") {
                    NavigationLink(value: AppSidebarItem.home) {
                        Label("Home", systemImage: "house")
                            .accessibilityIdentifier("sidebar_home")
                    }
                    .tag(AppSidebarItem.home)
                    .simultaneousGesture(TapGesture().onEnded {
                        showHomeOverview()
                    })
                    .accessibilityIdentifier("sidebar_home")

                    NavigationLink(value: AppSidebarItem.screen) {
                        Label("Displays", systemImage: "display")
                            .accessibilityIdentifier("sidebar_displays")
                    }
                    .tag(AppSidebarItem.screen)
                    .accessibilityIdentifier("sidebar_displays")

                    NavigationLink(value: AppSidebarItem.virtualDisplay) {
                        Label("Virtual Displays", systemImage: "display.2")
                            .accessibilityIdentifier("sidebar_virtual_display")
                    }
                    .tag(AppSidebarItem.virtualDisplay)
                    .accessibilityIdentifier("sidebar_virtual_display")

                    NavigationLink(value: AppSidebarItem.screenPreview) {
                        Label("Screen Preview", systemImage: "dot.scope.display")
                            .accessibilityIdentifier("sidebar_screen_preview")
                    }
                    .tag(AppSidebarItem.screenPreview)
                    .accessibilityIdentifier("sidebar_screen_preview")
                }

                Section("Sharing") {
                    NavigationLink(value: AppSidebarItem.screenSharing) {
                        Label("Screen Sharing", systemImage: "display")
                            .accessibilityIdentifier("sidebar_screen_sharing")
                    }
                    .tag(AppSidebarItem.screenSharing)
                    .accessibilityIdentifier("sidebar_screen_sharing")
                }

                Section(String(localized: "Diagnostics")) {
                    NavigationLink(value: AppSidebarItem.diagnostics) {
                        Label(String(localized: "Diagnostics"), systemImage: "stethoscope")
                            .accessibilityIdentifier("sidebar_diagnostics")
                    }
                    .tag(AppSidebarItem.diagnostics)
                    .accessibilityIdentifier("sidebar_diagnostics")
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("home_sidebar")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            NavigationStack {
                Group {
                    switch bindableNavigation.sidebarSelection ?? .home {
                    case .home:
                        displayDestinationView
                            .navigationTitle(displayDestinationTitle)
                            .accessibilityIdentifier(displayDestinationAccessibilityIdentifier)
                    case .screen:
                        SystemDisplaysView(activityProvider: displayActivityProvider)
                            .navigationTitle("Displays")
                            .accessibilityIdentifier("detail_displays")
                    case .virtualDisplay:
                        virtualDisplayView
                            .navigationTitle("Virtual Displays")
                            .accessibilityIdentifier("detail_virtual_display")
                    case .screenPreview:
                        previewView
                            .navigationTitle("Screen Preview")
                            .accessibilityIdentifier("detail_screen_preview")
                    case .screenSharing:
                        lanWebView
                            .navigationTitle("Screen Sharing")
                            .accessibilityIdentifier("detail_screen_sharing")
                    case .diagnostics:
                        DiagnosticsView(
                            observability: observability,
                            feedbackController: feedbackController
                        )
                            .navigationTitle(String(localized: "Diagnostics"))
                            .accessibilityIdentifier("detail_diagnostics")
                    }
                }
                .id(detailIdentity)
                .toolbar {
                    if shouldShowDisplayOverviewToolbarButton {
                        ToolbarItem {
                            Button {
                                showHomeOverview()
                            } label: {
                                Label("Home", systemImage: "chevron.left")
                            }
                            .help(Text("Home"))
                            .accessibilityIdentifier("displays_overview_toolbar_button")
                        }
                    }
                }
            }
        }
        .onAppear {
            columnVisibility = .all
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
            virtualDisplayView
        case .preview:
            previewView
        case .lanWebView:
            lanWebView
        }
    }

    @ViewBuilder
    private var virtualDisplayView: some View {
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
    }

    private var previewView: some View {
        IsCapturing(
            catalogState: capture.displayCatalogState,
            previewActions: CaptureUIComposition.previewActions(
                capture: capture,
                displayRuntime: displayRuntime
            ),
            sharingStatusProvider: CaptureUIComposition.sharingStatusProvider(sharing: sharing),
            virtualDisplayStatusProvider: CaptureUIComposition.virtualDisplayStatusProvider(
                virtualDisplay: virtualDisplay
            ),
            catalogActions: CaptureUIComposition.catalogActions(
                displayRuntime: displayRuntime,
                openScreenCapturePrivacySettings: openScreenCapturePrivacySettings
            )
        )
    }

    private var lanWebView: some View {
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
                displayRuntime: displayRuntime,
                openScreenCapturePrivacySettings: openScreenCapturePrivacySettings
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

    private var displayDestinationTitle: LocalizedStringKey {
        switch displayDestination {
        case .overview:
            "Home"
        case .virtualDisplay:
            "Virtual Display"
        case .preview:
            "Preview"
        case .lanWebView:
            "LAN Web View"
        }
    }

    private var displayDestinationAccessibilityIdentifier: String {
        switch displayDestination {
        case .overview:
            "detail_home"
        case .virtualDisplay:
            "detail_virtual_display"
        case .preview:
            "detail_screen_preview"
        case .lanWebView:
            "detail_lan_web_view"
        }
    }

    private var detailIdentity: String {
        switch navigation.sidebarSelection ?? .home {
        case .home:
            "home-\(displayDestination.rawValue)"
        case .screen:
            "displays"
        case .virtualDisplay:
            "virtualDisplay"
        case .screenPreview:
            "screenPreview"
        case .screenSharing:
            "screenSharing"
        case .diagnostics:
            "diagnostics"
        }
    }

    private var shouldShowDisplayOverviewToolbarButton: Bool {
        (navigation.sidebarSelection ?? .home) == .home && displayDestination != .overview
    }

    private func showHomeOverview() {
        displayDestination = .overview
        navigation.sidebarSelection = .home
    }

    private func openDisplayDestination(_ destination: DisplayDestination) {
        displayDestination = destination
        navigation.sidebarSelection = .home
    }

    private func autoOpenCapturePreviewWindowIfNeeded() {
        guard CapturePreviewDiagnosticsRuntime.shouldAutoOpenPreviewWindow,
              !hasAutoOpenedCapturePreview,
              let sessionID = capture.screenPreviewSessions.first?.id
        else {
            return
        }

        navigation.sidebarSelection = .screenPreview
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
            isPreviewing: capture.screenPreviewSessions.contains { $0.displayID == displayID },
            isSharing: sharing.isDisplaySharing(displayID: displayID)
        )
    }
}

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    HomeView(
        observability: env.observability,
        feedbackController: env.feedbackController,
        displayRuntime: env.displayRuntime,
        openScreenCapturePrivacySettings: env.openScreenCapturePrivacySettings
    )
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
        .environment(env.capturePerformancePreferences)
        .environment(AppNavigationController())
}
