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
    @State var selectedConfigId: UUID?

    @State private var showDeleteConfirm = false
    @State private var deleteCandidate: VirtualDisplayConfig?
    
    // Error handling
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        Group {
            if !appHelper.displayConfigs.isEmpty {
                List(appHelper.displayConfigs) { config in
                    let isRunning = appHelper.isVirtualDisplayRunning(configId: config.id)
                    HStack(alignment: .center) {
                        // Display icon with status indicator
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "display")
                                .font(.system(size: 30))
                                .foregroundColor(isRunning ? .primary : .secondary)
                            
                            // Status indicator
                            Circle()
                                .fill(isRunning ? Color.green : Color.gray)
                                .frame(width: 10, height: 10)
                                .offset(x: 2, y: 2)
                        }
                        
                        VStack(alignment: .leading) {
                            Text(config.name)
                                .font(.headline)
                                .foregroundColor(isRunning ? .primary : .secondary)
                            
                            HStack {
                                Text("Serial Number: \(config.serialNum)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Text("•")
                                    .foregroundColor(.secondary)
                                
                                Text(isRunning ? "Running" : "Disabled")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(isRunning ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                    .foregroundColor(isRunning ? .green : .gray)
                                    .cornerRadius(4)
                            }
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 8) {
                            // Enable/Disable toggle button
                            Button(action: {
                                toggleDisplayState(config)
                            }) {
                                Text(isRunning ? "Disable" : "Enable")
                                    .frame(width: 50)
                            }
                            .buttonStyle(.bordered)
                            .tint(isRunning ? .orange : .green)
                            
                            Button("Edit") {
                                selectedConfigId = config.id
                                editView = true
                            }
                            
                            // Destroy button
                            Button("Delete") {
                                deleteCandidate = config
                                showDeleteConfirm = true
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                    .opacity(isRunning ? 1.0 : 0.7)
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
            if let configId = selectedConfigId {
                EditVirtualDisplayConfigView(configId: configId, isShow: $editView)
                    .environmentObject(appHelper)
            } else {
                Text("No selection")
                    .padding()
            }
        }
        .toolbar {
            Button("Add Virtual Display", systemImage: "plus") {
                creatView = true
            }
        }
        .confirmationDialog(
            "Delete Virtual Display",
            isPresented: $showDeleteConfirm,
            presenting: deleteCandidate
        ) { config in
            Button("Delete", role: .destructive) {
                appHelper.destroyDisplay(config.id)
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { config in
            Text("This will remove the configuration and disable the display if it is running.\n\n\(config.name) (Serial \(config.serialNum))")
        }
        .alert("Enable Failed", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }
    
    private func toggleDisplayState(_ config: VirtualDisplayConfig) {
        if appHelper.isVirtualDisplayRunning(configId: config.id) {
            appHelper.disableDisplayByConfig(config.id)
            return
        }
        do {
            try appHelper.enableDisplay(config.id)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

#Preview {
    VirtualDisplayView()
}
