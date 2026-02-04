//
//  creatVirtualDisplay.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import Cocoa
import CoreGraphics

struct CreateVirtualDisplay: View {
    // MARK: - State Properties
    
    // Basic info
    @State private var name = "Virtual Display"
    @State private var serialNum: UInt32 = 1
    @State private var customSerialNum = false
    
    // Physical display
    @State private var screenDiagonal: Double = 14.0
    @State private var selectedAspectRatio: AspectRatio = .ratio_16_9
    
    // Resolution modes
    @State private var selectedModes: [ResolutionSelection] = []
    
    // Mode input
    @State private var usePresetMode = true
    @State private var presetResolution: Resolutions = .r_1920_1080
    @State private var customWidth: Int = 1920
    @State private var customHeight: Int = 1080
    @State private var customRefreshRate: Double = 60.0
    
    // Validation & alerts
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showDuplicateWarning = false
    
    // Focus state
    @FocusState private var isNameFocused: Bool
    
    @Binding var isShow: Bool
    @EnvironmentObject var appHelper: AppHelper
    
    // MARK: - Computed Properties
    
    private var physicalSize: (width: Int, height: Int) {
        selectedAspectRatio.sizeInMillimeters(diagonalInches: screenDiagonal)
    }
    
    private var maxPixelDimensions: (width: UInt32, height: UInt32) {
        guard let maxMode = selectedModes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
            return (1920, 1080)
        }
        // Check if any mode has HiDPI enabled
        let anyHiDPI = selectedModes.contains { $0.enableHiDPI }
        if anyHiDPI {
            return (UInt32(maxMode.width * 2), UInt32(maxMode.height * 2))
        }
        return (UInt32(maxMode.width), UInt32(maxMode.height))
    }
    
    private var aspectPreviewRatio: CGFloat {
        let components = selectedAspectRatio.components
        return CGFloat(components.width / components.height)
    }
    
    // MARK: - Body
    
    var body: some View {
        Form {
            // Basic Info Section
            Section {
                TextField("名称", text: $name)
                    .focused($isNameFocused)
                
                HStack {
                    Text("序列号")
                    Spacer()
                    if customSerialNum {
                        TextField("", value: $serialNum, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    } else {
                        Text("\(serialNum)")
                            .foregroundColor(.secondary)
                    }
                }
                
                Toggle("自定义序列号", isOn: $customSerialNum)
            } header: {
                Text("基本信息")
            }
            
            // Physical Display Section
            Section {
                HStack {
                    Text("屏幕尺寸")
                    Spacer()
                    TextField("", value: $screenDiagonal, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("英寸")
                }
                
                Picker("宽高比", selection: $selectedAspectRatio) {
                    ForEach(AspectRatio.allCases) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }
                
                HStack {
                    Text("物理尺寸")
                    Spacer()
                    Text("\(physicalSize.width) × \(physicalSize.height) mm")
                        .foregroundColor(.secondary)
                }
                
                // Aspect ratio preview
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .aspectRatio(aspectPreviewRatio, contentMode: .fit)
                        .frame(height: 60)
                        .overlay {
                            Text(selectedAspectRatio.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("物理显示")
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
                        // Preset mode
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
                        // Custom mode
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
                Text("每个分辨率可单独设置是否启用 HiDPI，启用后将自动生成 2x 物理像素模式")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("创建") {
                    createDisplayAction()
                }
                .disabled(selectedModes.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    isShow = false
                }
            }
        }
        .alert("错误", isPresented: $showError) {
            Button("确定") {}
        } message: {
            Text(errorMessage)
        }
        .alert("提示", isPresented: $showDuplicateWarning) {
            Button("确定") {}
        } message: {
            Text("该分辨率模式已存在")
        }
        .onAppear {
            serialNum = appHelper.nextAvailableSerialNumber()
            isNameFocused = true
            // Add a default mode
            if selectedModes.isEmpty {
                selectedModes.append(ResolutionSelection(preset: .r_1920_1080))
            }
        }
    }
    
    // MARK: - Actions
    
    private func addPresetMode() {
        let newMode = ResolutionSelection(preset: presetResolution)  // HiDPI defaults to true
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
        let newMode = ResolutionSelection(width: customWidth, height: customHeight, refreshRate: customRefreshRate)  // HiDPI defaults to true
        if selectedModes.contains(newMode) {
            showDuplicateWarning = true
        } else {
            selectedModes.append(newMode)
        }
    }
    
    private func removeMode(_ mode: ResolutionSelection) {
        selectedModes.removeAll { $0 == mode }
    }
    
    private func createDisplayAction() {
        let size = physicalSize
        
        do {
            _ = try appHelper.createDisplay(
                name: name,
                serialNum: serialNum,
                physicalSize: CGSize(width: size.width, height: size.height),
                maxPixels: maxPixelDimensions,
                modes: selectedModes
            )
            isShow = false
        } catch let error as AppHelper.VirtualDisplayError {
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = "创建失败: \(error.localizedDescription)"
            showError = true
        }
    }
}

#Preview {
//    CreateVirtualDisplay(isShow: .constant(true))
}
