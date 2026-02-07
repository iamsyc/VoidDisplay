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
                Section(String(localized: "Display")){
                    Label(String(localized: "Displays"), systemImage: "display")
                        .tag(SidebarItem.screen)
                        .accessibilityIdentifier("sidebar_screen")
                    Label(String(localized: "Virtual Displays"), systemImage: "display.2")
                        .tag(SidebarItem.virtualDisplay)
                        .accessibilityIdentifier("sidebar_virtual_display")
                    Label(String(localized: "Screen Monitoring"), systemImage: "dot.scope.display")
                        .tag(SidebarItem.monitorScreen)
                        .accessibilityIdentifier("sidebar_monitor_screen")
                }
                Section(String(localized: "Sharing")){
                    Label(String(localized: "Screen Sharing"), systemImage: "display")
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
                            .navigationTitle(String(localized: "Displays"))
                            .accessibilityIdentifier("detail_screen")
                    case .virtualDisplay:
                        VirtualDisplayView()
                            .navigationTitle(String(localized: "Virtual Displays"))
                            .accessibilityIdentifier("detail_virtual_display")
                    case .monitorScreen:
                        IsCapturing()
                            .navigationTitle(String(localized: "Screen Monitoring"))
                            .accessibilityIdentifier("detail_monitor_screen")
                    case .screenSharing:
                        ShareView()
                            .navigationTitle(String(localized: "Screen Sharing"))
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
