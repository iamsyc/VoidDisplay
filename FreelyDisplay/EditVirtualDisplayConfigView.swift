import SwiftUI

struct EditVirtualDisplayConfigView: View {
    let configId: UUID
    @Binding var isShow: Bool

    @EnvironmentObject var appHelper: AppHelper

    @State private var loadedConfig: VirtualDisplayConfig?

    @State private var name: String = ""
    @State private var serialNum: Int = 1
    @State private var selectedModes: [ResolutionSelection] = []

    @State private var usePresetMode = true
    @State private var presetResolution: Resolutions = .r_1920_1080
    @State private var customWidth: Int = 1920
    @State private var customHeight: Int = 1080
    @State private var customRefreshRate: Double = 60.0

    @State private var showDuplicateWarning = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showRebuildPrompt = false

    private var isRunning: Bool {
        appHelper.runtimeDisplay(for: configId) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)

                HStack {
                    Text("Serial Number")
                    Spacer()
                    TextField("", value: $serialNum, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                if isRunning {
                    Text("Some changes require rebuild when the display is running.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Basic Info")
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

                            Button(action: addPresetMode) {
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
                                .monospacedDigit()
                                .controlSize(.small)

                            Text("×")
                                .foregroundColor(.secondary)

                            TextField("Height", value: $customHeight, format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .controlSize(.small)

                            Text("@")
                                .foregroundColor(.secondary)

                            TextField("Hz", value: $customRefreshRate, format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 44)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .controlSize(.small)

                            Text("Hz")
                                .foregroundColor(.secondary)

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
                Text("Each resolution can enable HiDPI; when enabled, a 2× physical-pixel mode is generated automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedModes.isEmpty)
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
        .alert("Rebuild Required", isPresented: $showRebuildPrompt) {
            Button("Save Only") {
                isShow = false
            }
            Button("Rebuild Now") {
                rebuildNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Name or serial number changes require recreating the virtual display to take effect.")
        }
        .onAppear {
            load()
        }
    }

    private func load() {
        guard let config = appHelper.getConfig(configId) else {
            errorMessage = String(localized: "Display configuration not found.")
            showError = true
            return
        }

        loadedConfig = config
        name = config.name
        serialNum = Int(config.serialNum)
        selectedModes = config.resolutionModes

        if let first = selectedModes.first {
            customWidth = first.width
            customHeight = first.height
            customRefreshRate = first.refreshRate
        }
    }

    private func save() {
        guard let original = loadedConfig else {
            errorMessage = String(localized: "Display configuration not found.")
            showError = true
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        guard serialNum > 0, serialNum <= Int(UInt32.max) else {
            errorMessage = String(localized: "Please enter a valid serial number.")
            showError = true
            return
        }

        let newSerial = UInt32(serialNum)
        if appHelper.displayConfigs.contains(where: { $0.id != configId && $0.serialNum == newSerial }) {
            errorMessage = String(localized: "Serial number \(newSerial) is already in use.")
            showError = true
            return
        }

        var updated = original
        updated.name = trimmedName
        updated.serialNum = newSerial
        updated.modes = selectedModes.map {
            VirtualDisplayConfig.ModeConfig(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }
        appHelper.updateConfig(updated)
        loadedConfig = updated

        let needsRebuild = isRunning && (original.name != updated.name || original.serialNum != updated.serialNum)
        if needsRebuild {
            showRebuildPrompt = true
            return
        }

        if isRunning {
            appHelper.applyModes(configId: configId, modes: selectedModes)
        }
        isShow = false
    }

    private func rebuildNow() {
        do {
            try appHelper.rebuildVirtualDisplay(configId: configId)
            appHelper.applyModes(configId: configId, modes: selectedModes)
            isShow = false
        } catch {
            errorMessage = error.localizedDescription
            showError = true
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
}

