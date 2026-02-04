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
                    Text("Name")
                    Spacer()
                    Text(display.name)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Serial Number")
                    Spacer()
                    Text(String(display.serialNum))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Physical Size")
                    Spacer()
                    Text("\(Int(display.sizeInMillimeters.width)) × \(Int(display.sizeInMillimeters.height)) mm")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Display Info")
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
                                Text("\(mode.width) × \(mode.height) @ \(Int(mode.refreshRate))Hz")
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
                    Picker("Add Method", selection: $usePresetMode) {
                        Text("Preset").tag(true)
                        Text("Custom").tag(false)
                    }
                    .pickerStyle(.segmented)
                    
                    if usePresetMode {
                        HStack {
                            Picker("Preset Resolution", selection: $presetResolution) {
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
                            TextField("Width", value: $customWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("×")
                            TextField("Height", value: $customHeight, format: .number)
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
                Text("Resolution Modes")
            } footer: {
                Text("Each resolution can enable HiDPI.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 500)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    applySettings()
                }
                .disabled(selectedModes.isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    isShow = false
                }
            }
        }
        .alert("Tip", isPresented: $showDuplicateWarning) {
            Button("OK") {}
        } message: {
            Text("This resolution mode already exists.")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
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
        let newMode = ResolutionSelection(width: customWidth, height: customHeight, refreshRate: customRefreshRate)
        if selectedModes.contains(where: { $0.matchesResolution(of: newMode) }) {
            showDuplicateWarning = true
        } else {
            selectedModes.append(newMode)
        }
    }
    
    private func removeMode(_ mode: ResolutionSelection) {
        selectedModes.removeAll { $0.id == mode.id }
    }
    
    private func applySettings() {
        guard !selectedModes.isEmpty else {
            errorMessage = String(localized: "At least one resolution mode is required.")
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
        
        // Update stored config with new modes
        appHelper.updateConfig(for: display, modes: selectedModes)
        
        // Refresh the display list
        appHelper.id = UUID()
        
        isShow = false
    }
}
