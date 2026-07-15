import Foundation
import SwiftUI
import VoidDisplayCapture
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplaySupport
import VoidDisplayVirtualDisplay

package struct HomeView: View {
    @Environment(AppNavigationController.self) private var navigation
    @Environment(CaptureController.self) private var capture
    @Environment(SharingController.self) private var sharing
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @Environment(CapturePerformancePreferences.self) private var capturePerformancePreferences
    @Environment(AppearancePreferences.self) private var appearancePreferences

    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController
    private let displayRuntime: DisplayRuntime
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
                Section("Main") {
                    NavigationLink(value: AppSidebarItem.home) {
                        Label(String(localized: "Displays"), systemImage: "display.2")
                    }
                    .tag(AppSidebarItem.home)
                    .accessibilityIdentifier("sidebar_home")
                }

                Section(String(localized: "Diagnostics")) {
                    NavigationLink(value: AppSidebarItem.diagnostics) {
                        Label(String(localized: "Diagnostics"), systemImage: "stethoscope")
                    }
                    .tag(AppSidebarItem.diagnostics)
                    .accessibilityIdentifier("sidebar_diagnostics")
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("home_sidebar")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            NavigationStack {
                Group {
                    switch bindableNavigation.sidebarSelection ?? .home {
                    case .home:
                        HomeVirtualDisplaySurfaceView(
                            capture: capture,
                            sharing: sharing,
                            virtualDisplay: virtualDisplay,
                            capturePerformancePreferences: capturePerformancePreferences,
                            displayRuntime: displayRuntime,
                            openScreenCapturePrivacySettings: openScreenCapturePrivacySettings
                        )
                        .appSkin(appearancePreferences.skinID)
                        .navigationTitle(String(localized: "Displays"))
                        .accessibilityIdentifier("detail_home")
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
            }
        }
        .onAppear {
            columnVisibility = .all
        }
    }

    private var detailIdentity: String {
        switch navigation.sidebarSelection ?? .home {
        case .home:
            "home"
        case .diagnostics:
            "diagnostics"
        }
    }
}
