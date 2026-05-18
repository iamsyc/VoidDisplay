import AppKit
import Foundation
import SwiftUI
import VoidDisplayCapture
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
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var contentFocusRequest = 0

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
                        Label("Home", systemImage: "house")
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
                        .navigationTitle("Home")
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
            .background(alignment: .topLeading) {
                HomeContentFocusAnchor(request: contentFocusRequest)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            columnVisibility = .all
            requestContentFocus()
        }
    }

    private func requestContentFocus() {
        contentFocusRequest &+= 1
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

private struct HomeContentFocusAnchor: NSViewRepresentable {
    let request: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> SilentFocusView {
        SilentFocusView()
    }

    func updateNSView(_ nsView: SilentFocusView, context: Context) {
        guard context.coordinator.lastRequest != request else {
            return
        }
        context.coordinator.lastRequest = request
        nsView.requestFocus()
    }

    final class Coordinator {
        var lastRequest: Int?
    }
}

private final class SilentFocusView: NSView {
    private var shouldApplyFocus = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    func requestFocus() {
        shouldApplyFocus = true
        DispatchQueue.main.async { [weak self] in
            self?.applyFocusIfPossible()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFocusIfPossible()
    }

    private func applyFocusIfPossible() {
        guard shouldApplyFocus, let window else {
            return
        }
        shouldApplyFocus = false
        window.makeFirstResponder(self)
    }
}
