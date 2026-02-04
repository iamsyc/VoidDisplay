//
//  VirtualDisplay.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI

struct VirtualDisplayView: View {
    @EnvironmentObject var appHelper: AppHelper
    @State var creatView = false
    @State var editView = false
    @State var selectedConfig: VirtualDisplayConfig?
    
    // Error handling
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        Group {
            if !appHelper.displayConfigs.isEmpty {
                List(appHelper.displayConfigs) { config in
                    HStack(alignment: .center) {
                        // Display icon with status indicator
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "display")
                                .font(.system(size: 30))
                                .foregroundColor(config.isEnabled ? .primary : .secondary)
                            
                            // Status indicator
                            Circle()
                                .fill(config.isEnabled ? Color.green : Color.gray)
                                .frame(width: 10, height: 10)
                                .offset(x: 2, y: 2)
                        }
                        
                        VStack(alignment: .leading) {
                            Text(config.name)
                                .font(.headline)
                                .foregroundColor(config.isEnabled ? .primary : .secondary)
                            
                            HStack {
                                Text("Serial Number: \(config.serialNum)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Text("•")
                                    .foregroundColor(.secondary)
                                
                                Text(config.isEnabled ? "Running" : "Disabled")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(config.isEnabled ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                    .foregroundColor(config.isEnabled ? .green : .gray)
                                    .cornerRadius(4)
                            }
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 8) {
                            // Enable/Disable toggle button
                            Button(action: {
                                toggleDisplayState(config)
                            }) {
                                Text(config.isEnabled ? "Disable" : "Enable")
                                    .frame(width: 50)
                            }
                            .buttonStyle(.bordered)
                            .tint(config.isEnabled ? .orange : .green)
                            
                            // Edit button (only for enabled displays)
                            if config.isEnabled {
                                Button("Edit") {
                                    selectedConfig = config
                                    editView = true
                                }
                            }
                            
                            // Destroy button
                            Button("Destroy") {
                                appHelper.destroyDisplay(config.id)
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                    .opacity(config.isEnabled ? 1.0 : 0.7)
                }
            } else {
                ContentUnavailableView(
                    "No Virtual Displays",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("Click the + button in the top right to create a virtual display.")
                )
            }
        }
        .id(appHelper.id)
        .sheet(isPresented: $creatView) {
            CreateVirtualDisplay(isShow: $creatView)
        }
        .sheet(isPresented: $editView) {
            if let config = selectedConfig,
               let display = appHelper.displays.first(where: { $0.serialNum == config.serialNum }) {
                EditDisplaySettingsView(display: display, isShow: $editView)
                    .environmentObject(appHelper)
            }
        }
        .toolbar {
            Button("Add Virtual Display", systemImage: "plus") {
                creatView = true
            }
        }
        .alert("Enable Failed", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }
    
    private func toggleDisplayState(_ config: VirtualDisplayConfig) {
        if config.isEnabled {
            // Disable: save config and destroy display
            appHelper.disableDisplayByConfig(config.id)
        } else {
            // Enable: recreate display from config
            do {
                try appHelper.enableDisplay(config.id)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

#Preview {
    VirtualDisplayView()
}
