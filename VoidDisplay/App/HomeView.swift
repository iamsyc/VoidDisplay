//
//  HomeView.swift
//  VoidDisplay
//
//

import SwiftUI

struct HomeView: View {
    @Environment(CaptureController.self) private var capture
    @Environment(SharingController.self) private var sharing
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @Environment(\.openWindow) private var openWindow

    private enum SidebarItem: Hashable {
        case screen
        case virtualDisplay
        case monitorScreen
        case screenSharing
    }

    @State private var selection: SidebarItem? = .screen
    @State private var hasAutoOpenedCapturePreview = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Display") {
                    Label("Displays", systemImage: "display")
                        .tag(SidebarItem.screen)
                        .accessibilityIdentifier("sidebar_screen")
                    Label("Virtual Displays", systemImage: "display.2")
                        .tag(SidebarItem.virtualDisplay)
                        .accessibilityIdentifier("sidebar_virtual_display")
                    Label("Screen Monitoring", systemImage: "dot.scope.display")
                        .tag(SidebarItem.monitorScreen)
                        .accessibilityIdentifier("sidebar_monitor_screen")
                }

                Section("Sharing") {
                    Label("Screen Sharing", systemImage: "display")
                        .tag(SidebarItem.screenSharing)
                        .accessibilityIdentifier("sidebar_screen_sharing")
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("home_sidebar")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            NavigationStack {
                Group {
                    switch selection ?? .screen {
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
                        IsCapturing(capture: capture, virtualDisplay: virtualDisplay)
                            .navigationTitle("Screen Monitoring")
                            .accessibilityIdentifier("detail_monitor_screen")
                    case .screenSharing:
                        ShareView(sharing: sharing, virtualDisplay: virtualDisplay)
                            .navigationTitle("Screen Sharing")
                            .accessibilityIdentifier("detail_screen_sharing")
                    }
                }
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

        selection = .monitorScreen
        openWindow(value: sessionID)
        hasAutoOpenedCapturePreview = true
    }
}

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    HomeView()
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}
