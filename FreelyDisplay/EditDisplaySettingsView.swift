//
//  EditDisplaySettingsView.swift
//  FreelyDisplay
//
//  Edit settings for an existing virtual display
//

import SwiftUI
import CoreGraphics

struct EditDisplaySettingsView: View {
    let display: CGVirtualDisplay
    @Binding var isShow: Bool
    
    // Editable settings - use modes with per-resolution HiDPI
    @State private var selectedModes: [ResolutionSelection] = []
    
    // Mode input
    @State private var usePresetMode = true
    @State private var presetResolution: Resolutions = .r_1920_1080
    @State private var customWidth: Int = 1920
    @State private var customHeight: Int = 1080
    @State private var customRefreshRate: Double = 60.0
    
    // Alerts
    @State private var showDuplicateWarning = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    @EnvironmentObject var appHelper: AppHelper
    
    var body: some View {
        Form {
            // Display Info (Read-only)
            Section {
                HStack {
                    Text("名称")
                    Spacer()
                    Text(display.name)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("序列号")
                    Spacer()
                    Text(String(display.serialNum))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("物理尺寸")
                    Spacer()
                    Text("\(Int(display.sizeInMillimeters.width)) × \(Int(display.sizeInMillimeters.height)) mm")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("显示器信息")
            }
            
            // Resolution Modes Section
            Section {
                // Mode list
                if selectedModes.isEmpty {
                    Text("尚未添加分辨率模式")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach($selectedModes) { $mode in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(mode.width) × \(mode.height) @ \(Int(mode.refreshRate))Hz")
                                if mode.enableHiDPI {
                                    Text("HiDPI 已启用")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: $mode.enableHiDPI)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .scaleEffect(0.8)
                            Button(action: { removeMode(mode) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                Divider()
                
                // Add mode controls
                VStack(alignment: .leading, spacing: 8) {
                    Picker("添加方式", selection: $usePresetMode) {
                        Text("从预设").tag(true)
                        Text("自定义").tag(false)
                    }
                    .pickerStyle(.segmented)
                    
                    if usePresetMode {
                        HStack {
                            Picker("预设分辨率", selection: $presetResolution) {
                                ForEach(Resolutions.allCases) { res in
                                    Text("\(res.resolutions.0) × \(res.resolutions.1)")
                                        .tag(res)
                                }
                            }
                            .labelsHidden()
                            
                            Button(action: addPresetMode) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        HStack {
                            TextField("宽", value: $customWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("×")
                            TextField("高", value: $customHeight, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("@")
                            TextField("Hz", value: $customRefreshRate, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                            Text("Hz")
                            
                            Button(action: addCustomMode) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("分辨率模式")
            } footer: {
                Text("每个分辨率可单独设置是否启用 HiDPI")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 500)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("应用") {
                    applySettings()
                }
                .disabled(selectedModes.isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    isShow = false
                }
            }
        }
        .alert("提示", isPresented: $showDuplicateWarning) {
            Button("确定") {}
        } message: {
            Text("该分辨率模式已存在")
        }
        .alert("错误", isPresented: $showError) {
            Button("确定") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            initializeFromDisplay()
        }
    }
    
    // MARK: - Actions
    
    private func initializeFromDisplay() {
        // Initialize with a default mode based on current display
        // Since we can't easily read existing modes, start with a common resolution
        let isHiDPI = display.hiDPI > 0
        selectedModes = [ResolutionSelection(preset: .r_1920_1080, enableHiDPI: isHiDPI)]
    }
    
    private func addPresetMode() {
        let newMode = ResolutionSelection(preset: presetResolution)
        if selectedModes.contains(newMode) {
            showDuplicateWarning = true
        } else {
            selectedModes.append(newMode)
        }
    }
    
    private func addCustomMode() {
        guard customWidth > 0, customHeight > 0, customRefreshRate > 0 else {
            errorMessage = "请输入有效的分辨率值"
            showError = true
            return
        }
        let newMode = ResolutionSelection(width: customWidth, height: customHeight, refreshRate: customRefreshRate)
        if selectedModes.contains(newMode) {
            showDuplicateWarning = true
        } else {
            selectedModes.append(newMode)
        }
    }
    
    private func removeMode(_ mode: ResolutionSelection) {
        selectedModes.removeAll { $0 == mode }
    }
    
    private func applySettings() {
        guard !selectedModes.isEmpty else {
            errorMessage = "至少需要一个分辨率模式"
            showError = true
            return
        }
        
        let settings = CGVirtualDisplaySettings()
        
        // Enable HiDPI if any mode has HiDPI enabled
        let anyHiDPI = selectedModes.contains { $0.enableHiDPI }
        settings.hiDPI = anyHiDPI ? 1 : 0
        
        // Build modes array
        var displayModes: [CGVirtualDisplayMode] = []
        
        for mode in selectedModes {
            if mode.enableHiDPI {
                let hiDPIMode = mode.hiDPIVersion()
                displayModes.append(hiDPIMode.toVirtualDisplayMode())
            }
            displayModes.append(mode.toVirtualDisplayMode())
        }
        
        settings.modes = displayModes
        
        // Apply settings to existing display
        display.apply(settings)
        
        // Refresh the display list
        appHelper.id = UUID()
        
        isShow = false
    }
}

