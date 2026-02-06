//
//  ContentView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
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

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Monitor"){
                    Label("Screen", systemImage: "display")
                        .tag(SidebarItem.screen)
                        .accessibilityIdentifier("sidebar_screen")
                    Label("Virtual Display", systemImage: "display.2")
                        .tag(SidebarItem.virtualDisplay)
                        .accessibilityIdentifier("sidebar_virtual_display")
                    Label("Monitor Screen", systemImage: "dot.scope.display")
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
                    switch selection ?? .screen {
                    case .screen:
                        DisplaysView()
                            .navigationTitle("Screen")
                            .accessibilityIdentifier("detail_screen")
                    case .virtualDisplay:
                        VirtualDisplayView()
                            .navigationTitle("Virtual Display")
                            .accessibilityIdentifier("detail_virtual_display")
                    case .monitorScreen:
                        IsCapturing()
                            .navigationTitle("Monitor Screen")
                            .accessibilityIdentifier("detail_monitor_screen")
                    case .screenSharing:
                        ShareView()
                            .navigationTitle("Screen Sharing")
                            .accessibilityIdentifier("detail_screen_sharing")
                    }
                }
            }
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
