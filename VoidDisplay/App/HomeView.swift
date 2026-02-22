//
//  ContentView.swift
//  VoidDisplay
//
//

import SwiftUI

struct HomeView: View {
    private enum SidebarItem: Hashable {
        case screen
        case virtualDisplay
        case monitorScreen
        case screenSharing
    }

    @State private var selection: SidebarItem? = .screen

    private var activeSelection: SidebarItem {
        selection ?? .screen
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Display"){
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
                Section("Sharing"){
                    Label("Screen Sharing", systemImage: "display")
                        .tag(SidebarItem.screenSharing)
                        .accessibilityIdentifier("sidebar_screen_sharing")
                    
                }
            }
            .accessibilityIdentifier("home_sidebar")
            .navigationSplitViewColumnWidth(min: 160, ideal: 160,max: 190)
        } detail: {
            NavigationStack {
                Group {
                    switch activeSelection {
                    case .screen:
                        DisplaysView()
                            .navigationTitle("Displays")
                            .accessibilityIdentifier("detail_screen")
                    case .virtualDisplay:
                        VirtualDisplayView()
                            .navigationTitle("Virtual Displays")
                            .accessibilityIdentifier("detail_virtual_display")
                    case .monitorScreen:
                        IsCapturing()
                            .navigationTitle("Screen Monitoring")
                            .accessibilityIdentifier("detail_monitor_screen")
                    case .screenSharing:
                        ShareView()
                            .navigationTitle("Screen Sharing")
                            .accessibilityIdentifier("detail_screen_sharing")
                    }
                }
            }
            .id(activeSelection)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .onAppear {
            if selection == nil {
                selection = .screen
            }
        }
        
    }
}

#Preview {
    HomeView()
        .environment(AppHelper(preview: true))
}
