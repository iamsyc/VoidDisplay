import SwiftUI
import OSLog

struct EditVirtualDisplayConfigView: View {
    private struct SaveAnalysis {
        let updatedConfig: VirtualDisplayConfig
        let shouldApplyModesImmediately: Bool
    }

    let configId: UUID

    @Environment(AppHelper.self) private var appHelper: AppHelper
    @Environment(\.dismiss) private var dismiss

    @State private var loadedConfig: VirtualDisplayConfig?

    @State private var name: String = ""
    @State private var serialNum: Int = 1
    @State private var selectedModes: [ResolutionSelection] = []

    // Physical display
    @State private var screenDiagonal: Double = 14.0
    @State private var selectedAspectRatio: AspectRatio = .ratio_16_9
    @State private var initialScreenDiagonal: Double = 14.0
    @State private var initialAspectRatio: AspectRatio = .ratio_16_9

    @State private var usePresetMode = true
    @State private var presetResolution: DisplayResolutionPreset = .w1920h1080
    @State private var customWidth: Int = 1920
    @State private var customHeight: Int = 1080
    @State private var customRefreshRate: Double = 60.0

    @State private var showDuplicateWarning = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var isRunning: Bool {
        appHelper.isVirtualDisplayRunning(configId: configId)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSaveBlockedByMissingRequiredFields: Bool {
        trimmedName.isEmpty || selectedModes.isEmpty
    }

    private var physicalSizeFromInputs: (width: Int, height: Int) {
        selectedAspectRatio.sizeInMillimeters(diagonalInches: screenDiagonal)
    }

    private var aspectPreviewRatio: CGFloat {
        let components = selectedAspectRatio.components
        return CGFloat(components.width / components.height)
    }

    private var displayedPhysicalSizeText: String {
        guard let loadedConfig else {
            return "\(physicalSizeFromInputs.width) × \(physicalSizeFromInputs.height) mm"
        }

        let unchanged = abs(screenDiagonal - initialScreenDiagonal) < 0.0001 && selectedAspectRatio == initialAspectRatio
        let size: (width: Int, height: Int) = unchanged
            ? (width: loadedConfig.physicalWidth, height: loadedConfig.physicalHeight)
            : physicalSizeFromInputs
        return "\(size.width) × \(size.height) mm"
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("virtual_display_edit_name_field")

                HStack {
                    Text("Serial Number")
                    Spacer()
                    TextField("", value: $serialNum, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityIdentifier("virtual_display_edit_serial_field")
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
                HStack {
                    Text("Screen Size")
                    Spacer()
                    TextField("", value: $screenDiagonal, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("inches")
                }

                Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                    ForEach(AspectRatio.allCases) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }

                HStack {
                    Text("Physical Size")
                    Spacer()
                    Text(verbatim: displayedPhysicalSizeText)
                        .foregroundColor(.secondary)
                }

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
                                    .accessibilityIdentifier("virtual_display_edit_mode_hidpi_toggle")
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
                                ForEach(DisplayResolutionPreset.allCases) { res in
                                    Text(verbatim: "\(res.displayText) @ 60Hz")
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
        .frame(width: 480, height: 580)
        .accessibilityIdentifier("edit_virtual_display_form")
        .safeAreaInset(edge: .bottom) {
            editActionBar
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
            load()
        }
    }

    @ViewBuilder
    private var editActionBar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("virtual_display_edit_cancel_button")

            if !isRunning {
                Button("Save") {
                    handleSaveOnlyTapped()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveBlockedByMissingRequiredFields)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("virtual_display_edit_save_button")
            } else {
                Button("Save Only") {
                    handleSaveOnlyTapped()
                }
                .disabled(isSaveBlockedByMissingRequiredFields)
                .accessibilityIdentifier("virtual_display_edit_save_only_button")

                Button("Save and Rebuild Now") {
                    handleSaveAndRebuildTapped()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveBlockedByMissingRequiredFields)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("virtual_display_edit_save_and_rebuild_button")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
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

        let physicalWidth = Double(config.physicalWidth)
        let physicalHeight = Double(config.physicalHeight)
        if physicalWidth > 0, physicalHeight > 0 {
            let inferredRatio = physicalWidth / physicalHeight
            let closestRatio = AspectRatio.allCases.min { lhs, rhs in
                let l = abs((lhs.components.width / lhs.components.height) - inferredRatio)
                let r = abs((rhs.components.width / rhs.components.height) - inferredRatio)
                return l < r
            } ?? .ratio_16_9

            let diagonal = sqrt(physicalWidth * physicalWidth + physicalHeight * physicalHeight) / 25.4
            let rounded = (diagonal * 10).rounded() / 10

            selectedAspectRatio = closestRatio
            screenDiagonal = rounded
            initialAspectRatio = closestRatio
            initialScreenDiagonal = rounded
        }

        if let first = selectedModes.first {
            customWidth = first.width
            customHeight = first.height
            customRefreshRate = first.refreshRate
        }
    }

    private func buildUpdatedConfig(reportErrors: Bool) -> VirtualDisplayConfig? {
        guard let original = loadedConfig else {
            guard reportErrors else { return nil }
            errorMessage = String(localized: "Display configuration not found.")
            showError = true
            return nil
        }

        guard !trimmedName.isEmpty else { return nil }

        guard !selectedModes.isEmpty else {
            guard reportErrors else { return nil }
            errorMessage = String(localized: "No resolution modes added")
            showError = true
            return nil
        }

        guard serialNum > 0, serialNum <= Int(UInt32.max) else {
            guard reportErrors else { return nil }
            errorMessage = String(localized: "Please enter a valid serial number.")
            showError = true
            return nil
        }

        guard screenDiagonal > 0 else {
            guard reportErrors else { return nil }
            errorMessage = String(localized: "Please enter a valid screen size.")
            showError = true
            return nil
        }

        let newSerial = UInt32(serialNum)
        if appHelper.displayConfigs.contains(where: { $0.id != configId && $0.serialNum == newSerial }) {
            guard reportErrors else { return nil }
            errorMessage = String(localized: "Serial number \(newSerial) is already in use.")
            showError = true
            return nil
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

        let physicalInputsChanged = abs(screenDiagonal - initialScreenDiagonal) >= 0.0001 || selectedAspectRatio != initialAspectRatio
        if physicalInputsChanged {
            let size = physicalSizeFromInputs
            updated.physicalWidth = size.width
            updated.physicalHeight = size.height
        }

        return updated
    }

    private func analyzeSave(reportErrors: Bool) -> SaveAnalysis? {
        guard let original = loadedConfig else { return nil }
        guard let updated = buildUpdatedConfig(reportErrors: reportErrors) else { return nil }

        let newMaxPixels = updated.maxPixelDimensions
        let oldMaxPixels = original.maxPixelDimensions
        let requiresSaveAndRebuild = isRunning && (
            original.name != updated.name ||
            original.serialNum != updated.serialNum ||
            original.physicalWidth != updated.physicalWidth ||
            original.physicalHeight != updated.physicalHeight ||
            newMaxPixels.width > oldMaxPixels.width ||
            newMaxPixels.height > oldMaxPixels.height
        )

        return SaveAnalysis(
            updatedConfig: updated,
            shouldApplyModesImmediately: isRunning && !requiresSaveAndRebuild
        )
    }

    private func handleSaveOnlyTapped() {
        guard let analysis = analyzeSave(reportErrors: true) else { return }
        performSaveOnly(analysis)
    }

    private func handleSaveAndRebuildTapped() {
        guard isRunning else { return }
        guard let analysis = analyzeSave(reportErrors: true) else { return }
        performSaveAndRebuild(analysis)
    }

    private func performSaveOnly(_ analysis: SaveAnalysis) {
        appHelper.updateConfig(analysis.updatedConfig)
        loadedConfig = analysis.updatedConfig
        if analysis.shouldApplyModesImmediately {
            appHelper.applyModes(configId: configId, modes: selectedModes)
        }
        dismiss()
    }

    private func performSaveAndRebuild(_ analysis: SaveAnalysis) {
        appHelper.updateConfig(analysis.updatedConfig)
        loadedConfig = analysis.updatedConfig
        dismiss()
        appHelper.startRebuildFromSavedConfig(configId: configId)
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
