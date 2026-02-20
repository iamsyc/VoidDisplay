//
//  CreateVirtualDisplayObjectView.swift
//  FreelyDisplay
//
//

import SwiftUI
import CoreGraphics
import OSLog

struct CreateVirtualDisplay: View {
    // MARK: - State Properties
    
    // Basic info
    @State private var name = String(localized: "Virtual Display")
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
    private enum FocusField: Hashable {
        case name
        case serialNum
        case screenDiagonal
        case customWidth
        case customHeight
        case customRefreshRate
    }
    @FocusState private var focusedField: FocusField?
    
    @Binding var isShow: Bool
    @Environment(AppHelper.self) private var appHelper: AppHelper

    private func clearFocus() {
        focusedField = nil
    }

    private var baseDisplayName: String {
        String(localized: "Virtual Display")
    }

    private func defaultName(for serial: UInt32) -> String {
        "\(baseDisplayName) \(serial)"
    }
    
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
                TextField("Name", text: $name)
                    .focused($focusedField, equals: .name)
                
                HStack {
                    Text("Serial Number")
                    Spacer()
                    if customSerialNum {
                        TextField("", value: $serialNum, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .focused($focusedField, equals: .serialNum)
                    } else {
                        Text(serialNum, format: .number)
                            .foregroundColor(.secondary)
                    }
                }
                
                Toggle("Custom Serial Number", isOn: $customSerialNum)
            } header: {
                Text("Basic Info")
            }
            
            // Physical Display Section
            Section {
                HStack {
                    Text("Screen Size")
                    Spacer()
                    TextField("", value: $screenDiagonal, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .screenDiagonal)
                    Text("inches")
                }
                
                Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                    ForEach(AspectRatio.allCases) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }
                .onChange(of: selectedAspectRatio) { _, _ in
                    clearFocus()
                }
                
                HStack {
                    Text("Physical Size")
                    Spacer()
                    Text(verbatim: "\(physicalSize.width) × \(physicalSize.height) mm")
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    clearFocus()
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
                Text("Physical Display")
            }
            
            // Resolution Modes Section
            Section {
                // Mode list
                if selectedModes.isEmpty {
                    Text("No resolution modes added")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach($selectedModes) { $mode in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(mode.width) × \(mode.height) @ \(Int(mode.refreshRate))Hz")
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Text("HiDPI")
                                    .font(.caption)
                                    .foregroundColor($mode.enableHiDPI.wrappedValue ? .green : .secondary)
                                Toggle("", isOn: $mode.enableHiDPI)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .onChange(of: mode.enableHiDPI) { _, _ in
                                clearFocus()
                            }
                            Button(action: { removeMode(mode) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                Divider()
                
                Picker("Add Method", selection: $usePresetMode) {
                    Text("Preset").tag(true)
                    Text("Custom").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: usePresetMode) { _, _ in
                    clearFocus()
                }

                if usePresetMode {
                    LabeledContent(String(localized: "Preset")) {
                        HStack(spacing: 8) {
                            Picker("Preset Resolution", selection: $presetResolution) {
                                ForEach(Resolutions.allCases) { res in
                                    Text(verbatim: "\(res.resolutions.0) × \(res.resolutions.1) @ 60Hz")
                                        .tag(res)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: presetResolution) { _, _ in
                                clearFocus()
                            }

                            Button(action: {
                                clearFocus()
                                addPresetMode()
                            }) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    LabeledContent(String(localized: "Custom")) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            TextField("Width", value: $customWidth, format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .customWidth)
                                .monospacedDigit()
                                .controlSize(.small)

                            Text("×")
                                .foregroundColor(.secondary)

                            TextField("Height", value: $customHeight, format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .customHeight)
                                .monospacedDigit()
                                .controlSize(.small)

                            Text("@")
                                .foregroundColor(.secondary)

                            TextField("Hz", value: $customRefreshRate, format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 44)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .customRefreshRate)
                                .monospacedDigit()
                                .controlSize(.small)

                            Text("Hz")
                                .foregroundColor(.secondary)

                            Button(action: {
                                clearFocus()
                                addCustomMode()
                            }) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Resolution Modes")
            } footer: {
                Text("Each resolution can enable HiDPI; when enabled, a 2× physical-pixel mode is generated automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    clearFocus()
                    createDisplayAction()
                }
                .disabled(selectedModes.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    clearFocus()
                    isShow = false
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .alert("Tip", isPresented: $showDuplicateWarning) {
            Button("OK") {}
        } message: {
            Text("This resolution mode already exists.")
        }
        .onAppear {
            serialNum = appHelper.nextAvailableSerialNumber()
            if name == baseDisplayName {
                name = defaultName(for: serialNum)
            }
            focusedField = .name
            // Add a default mode
            if selectedModes.isEmpty {
                selectedModes.append(ResolutionSelection(preset: .r_1920_1080))
            }
        }
    }
    
    // MARK: - Actions
    
    private func addPresetMode() {
        let newMode = ResolutionSelection(preset: presetResolution)  // HiDPI defaults to true
        if selectedModes.contains(where: { $0.matchesResolution(of: newMode) }) {
            showDuplicateWarning = true
        } else {
            selectedModes.append(newMode)
        }
    }
    
    private func addCustomMode() {
        guard customWidth > 0, customHeight > 0, customRefreshRate > 0 else {
            errorMessage = String(localized: "Please enter valid resolution values.")
            showError = true
            return
        }
        let newMode = ResolutionSelection(width: customWidth, height: customHeight, refreshRate: customRefreshRate)  // HiDPI defaults to true
        if selectedModes.contains(where: { $0.matchesResolution(of: newMode) }) {
            showDuplicateWarning = true
        } else {
            selectedModes.append(newMode)
        }
    }
    
    private func removeMode(_ mode: ResolutionSelection) {
        selectedModes.removeAll { $0.id == mode.id }
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
            AppErrorMapper.logFailure("Create virtual display", error: error, logger: AppLog.virtualDisplay)
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            AppErrorMapper.logFailure("Create virtual display", error: error, logger: AppLog.virtualDisplay)
            errorMessage = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Create failed."))
            showError = true
        }
    }
}

#Preview {
//    CreateVirtualDisplay(isShow: .constant(true))
}
