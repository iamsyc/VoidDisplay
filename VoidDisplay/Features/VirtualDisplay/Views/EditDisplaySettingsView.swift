//
//  EditDisplaySettingsView.swift
//  VoidDisplay
//
//  Edit settings for an existing virtual display config.
//

import SwiftUI

struct EditDisplaySettingsView: View {
    let configId: UUID
    @Binding var isShow: Bool

    @State private var selectedModes: [ResolutionSelection] = []

    @State private var usePresetMode = true
    @State private var presetResolution: DisplayResolutionPreset = .w1920h1080
    @State private var customWidth: Int = 1920
    @State private var customHeight: Int = 1080
    @State private var customRefreshRate: Double = 60.0

    @State private var showDuplicateWarning = false
    @State private var showError = false
    @State private var errorMessage = ""

    @Environment(VirtualDisplayController.self) private var virtualDisplay

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Name")
                    Spacer()
                    Text(currentConfig?.displayName ?? "-")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Serial Number")
                    Spacer()
                    Text(currentConfig.map { String($0.serialNum) } ?? "-")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Physical Size")
                    Spacer()
                    Text(currentConfig.map { "\($0.physicalWidth) × \($0.physicalHeight) mm" } ?? "-")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Display Info")
            }

            Section {
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

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Add Method", selection: $usePresetMode) {
                        Text("Preset").tag(true)
                        Text("Custom").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if usePresetMode {
                        HStack {
                            Picker("Preset Resolution", selection: $presetResolution) {
                                ForEach(DisplayResolutionPreset.allCases) { res in
                                    Text(res.displayText)
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
                .disabled(selectedModes.isEmpty || currentConfig == nil)
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
        .alert("Save Failed", isPresented: persistenceErrorBinding) {
            Button("OK") {
                virtualDisplay.clearPersistenceError()
            }
        } message: {
            Text(virtualDisplay.persistenceErrorMessage)
        }
        .onAppear {
            initializeFromConfig()
        }
    }

    private var currentConfig: VirtualDisplayConfig? {
        virtualDisplay.getConfig(configId)
    }

    private func initializeFromConfig() {
        guard let config = currentConfig else {
            selectedModes = []
            return
        }
        selectedModes = config.resolutionModes
        if selectedModes.isEmpty {
            selectedModes = [ResolutionSelection(preset: .w1920h1080)]
        }
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
        guard var config = currentConfig else {
            errorMessage = String(localized: "Display configuration not found.")
            showError = true
            return
        }

        config.modes = selectedModes.map {
            .init(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }
        do {
            try virtualDisplay.updateConfig(config)
        } catch { return }
        virtualDisplay.applyModes(configId: config.id, modes: selectedModes)
        isShow = false
    }

    private var persistenceErrorBinding: Binding<Bool> {
        Binding(
            get: { virtualDisplay.showPersistenceError },
            set: { isPresented in
                if !isPresented {
                    virtualDisplay.clearPersistenceError()
                }
            }
        )
    }
}
