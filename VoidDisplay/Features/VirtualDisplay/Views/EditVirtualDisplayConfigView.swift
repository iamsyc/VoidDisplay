import SwiftUI
import OSLog

struct EditVirtualDisplayConfigView: View {
    let configId: UUID

    @Environment(VirtualDisplayController.self) private var virtualDisplay
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
        virtualDisplay.isVirtualDisplayRunning(configId: configId)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSaveBlockedByMissingRequiredFields: Bool {
        trimmedName.isEmpty || selectedModes.isEmpty
    }

    private var aspectPreviewRatio: CGFloat {
        let components = selectedAspectRatio.components
        return CGFloat(components.width / components.height)
    }

    private var displayedPhysicalSizeText: String {
        let size = VirtualDisplayEditSaveAnalyzer.displayedPhysicalSize(
            loadedConfig: loadedConfig,
            draft: saveDraft
        )
        return "\(size.width) × \(size.height) mm"
    }

    private var saveDraft: VirtualDisplayEditSaveAnalyzer.Draft {
        VirtualDisplayEditSaveAnalyzer.Draft(
            name: name,
            serialNum: serialNum,
            selectedModes: selectedModes,
            screenDiagonal: screenDiagonal,
            selectedAspectRatio: selectedAspectRatio,
            initialScreenDiagonal: initialScreenDiagonal,
            initialAspectRatio: initialAspectRatio
        )
    }

    var body: some View {
        Form {
            basicInfoSection
            physicalDisplaySection
            resolutionModesSection
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
    private var basicInfoSection: some View {
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
    }

    @ViewBuilder
    private var physicalDisplaySection: some View {
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
    }

    @ViewBuilder
    private var resolutionModesSection: some View {
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
        guard let config = virtualDisplay.getConfig(configId) else {
            errorMessage = String(localized: "Display configuration not found.")
            showError = true
            return
        }

        loadedConfig = config
        name = config.name
        serialNum = Int(config.serialNum)
        selectedModes = config.resolutionModes

        if let inferred = VirtualDisplayEditSaveAnalyzer.inferPhysicalInputs(from: config) {
            selectedAspectRatio = inferred.aspectRatio
            screenDiagonal = inferred.diagonalInches
            initialAspectRatio = inferred.aspectRatio
            initialScreenDiagonal = inferred.diagonalInches
        }

        if let first = selectedModes.first {
            customWidth = first.width
            customHeight = first.height
            customRefreshRate = first.refreshRate
        }
    }

    private func analyzeSave(reportErrors: Bool) -> VirtualDisplayEditSaveAnalyzer.SaveAnalysis? {
        let result = VirtualDisplayEditSaveAnalyzer.analyze(
            original: loadedConfig,
            configId: configId,
            draft: saveDraft,
            existingConfigs: virtualDisplay.displayConfigs,
            isRunning: isRunning
        )

        switch result {
        case .success(let analysis):
            return analysis
        case .failure(let error):
            guard reportErrors else { return nil }
            guard let message = validationErrorMessage(error) else { return nil }
            errorMessage = message
            showError = true
            return nil
        }
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

    private func performSaveOnly(_ analysis: VirtualDisplayEditSaveAnalyzer.SaveAnalysis) {
        virtualDisplay.updateConfig(analysis.updatedConfig)
        loadedConfig = analysis.updatedConfig
        if analysis.shouldApplyModesImmediately {
            virtualDisplay.applyModes(configId: configId, modes: selectedModes)
        }
        dismiss()
    }

    private func performSaveAndRebuild(_ analysis: VirtualDisplayEditSaveAnalyzer.SaveAnalysis) {
        virtualDisplay.updateConfig(analysis.updatedConfig)
        loadedConfig = analysis.updatedConfig
        dismiss()
        virtualDisplay.startRebuildFromSavedConfig(configId: configId)
    }

    private func addPresetMode() {
        switch CreateVirtualDisplayInputValidator.addPresetMode(preset: presetResolution, to: selectedModes) {
        case .appended(let updated):
            selectedModes = updated
        case .duplicate:
            showDuplicateWarning = true
        case .invalidValues:
            break
        }
    }

    private func addCustomMode() {
        switch CreateVirtualDisplayInputValidator.addCustomMode(
            width: customWidth,
            height: customHeight,
            refreshRate: customRefreshRate,
            to: selectedModes
        ) {
        case .appended(let updated):
            selectedModes = updated
        case .duplicate:
            showDuplicateWarning = true
        case .invalidValues:
            errorMessage = String(localized: "Please enter valid resolution values.")
            showError = true
        }
    }

    private func removeMode(_ mode: ResolutionSelection) {
        selectedModes.removeAll { $0.id == mode.id }
    }

    private func validationErrorMessage(
        _ error: VirtualDisplayEditSaveAnalyzer.ValidationError
    ) -> String? {
        switch error {
        case .configNotFound:
            return String(localized: "Display configuration not found.")
        case .emptyName:
            return nil
        case .noResolutionModes:
            return String(localized: "No resolution modes added")
        case .invalidSerialNumber:
            return String(localized: "Please enter a valid serial number.")
        case .invalidScreenSize:
            return String(localized: "Please enter a valid screen size.")
        case .duplicateSerialNumber(let serial):
            return String(localized: "Serial number \(serial) is already in use.")
        }
    }
}
