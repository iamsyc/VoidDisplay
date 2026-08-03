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

    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController
    private let displayRuntime: DisplayRuntime
    private let sharingAdapter: DisplayRuntimeSharingAdapter
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var isSidebarFocused: Bool

    package init(
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController,
        displayRuntime: DisplayRuntime,
        sharingAdapter: DisplayRuntimeSharingAdapter,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void
    ) {
        self.observability = observability
        self.feedbackController = feedbackController
        self.displayRuntime = displayRuntime
        self.sharingAdapter = sharingAdapter
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
    }

    package var body: some View {
        @Bindable var bindableNavigation = navigation

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $bindableNavigation.sidebarSelection) {
                NavigationLink(value: AppSidebarItem.home) {
                    Label(String(localized: "Displays"), systemImage: "display.2")
                }
                .tag(AppSidebarItem.home)
                .accessibilityIdentifier("sidebar_home")

                NavigationLink(value: AppSidebarItem.diagnostics) {
                    Label(String(localized: "Diagnostics"), systemImage: "stethoscope")
                }
                .tag(AppSidebarItem.diagnostics)
                .accessibilityIdentifier("sidebar_diagnostics")
            }
            .listStyle(.sidebar)
            .focused($isSidebarFocused)
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
                            sharingAdapter: sharingAdapter,
                            openScreenCapturePrivacySettings: openScreenCapturePrivacySettings,
                            restoreSidebarFocus: restoreSidebarFocus
                        )
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
            restoreSidebarFocus()
        }
    }

    private func restoreSidebarFocus() {
        guard columnVisibility != .detailOnly else { return }
        Task { @MainActor in
            await Task.yield()
            guard columnVisibility != .detailOnly else { return }
            isSidebarFocused = true
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
