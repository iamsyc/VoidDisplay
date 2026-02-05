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
                    Label("Virtual Display", systemImage: "display.2")
                        .tag(SidebarItem.virtualDisplay)
                    Label("Monitor Screen", systemImage: "dot.scope.display")
                        .tag(SidebarItem.monitorScreen)
                }
                Section("Sharing"){
                    Label("Screen Sharing", systemImage: "display")
                        .tag(SidebarItem.screenSharing)
                    
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 160,max: 190)
        } detail: {
            NavigationStack {
                Group {
                    switch selection ?? .screen {
                    case .screen:
                        DisplaysView()
                            .navigationTitle("Screen")
                    case .virtualDisplay:
                        VirtualDisplayView()
                            .navigationTitle("Virtual Display")
                    case .monitorScreen:
                        IsCapturing()
                            .navigationTitle("Monitor Screen")
                    case .screenSharing:
                        ShareView()
                            .navigationTitle("Screen Sharing")
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
}
