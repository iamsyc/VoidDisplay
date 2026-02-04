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
                                Text("序列号: \(config.serialNum)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Text("•")
                                    .foregroundColor(.secondary)
                                
                                Text(config.isEnabled ? "运行中" : "已停用")
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
                                Text(config.isEnabled ? "停用" : "启用")
                                    .frame(width: 50)
                            }
                            .buttonStyle(.bordered)
                            .tint(config.isEnabled ? .orange : .green)
                            
                            // Edit button (only for enabled displays)
                            if config.isEnabled {
                                Button("编辑") {
                                    selectedConfig = config
                                    editView = true
                                }
                            }
                            
                            // Destroy button
                            Button("销毁") {
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
                    "没有虚拟显示器",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("点击右上角的 + 按钮创建一个虚拟显示器")
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
            Button("添加虚拟显示器", systemImage: "plus") {
                creatView = true
            }
        }
        .alert("启用失败", isPresented: $showError) {
            Button("确定") {}
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

