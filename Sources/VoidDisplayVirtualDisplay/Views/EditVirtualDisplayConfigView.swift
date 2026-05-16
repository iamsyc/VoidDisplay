import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import SwiftUI
package struct EditVirtualDisplayConfigView: View {
    package let configId: UUID

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

    @State private var localAlert: UserFacingAlertState?
    @State private var isSaveAndRebuildInFlight = false

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

    package var body: some View {
        @Bindable var bindableVirtualDisplay = virtualDisplay

        Form {
            basicInfoSection
            physicalDisplaySection
            resolutionModesSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .accessibilityIdentifier("edit_virtual_display_form")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            editActionBar
        }
        .alert(item: $localAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message)
            )
        }
        .alert(item: $bindableVirtualDisplay.persistenceAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    virtualDisplay.dismissPersistenceAlert()
                }
            )
        }
        .onAppear {
            load()
        }
    }

    @ViewBuilder
    private var editActionBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 8) {
                if UITestRuntime.isEnabled && isRunning {
                    Button {
                        handleUITestSaveAndRebuildTapped()
                    } label: {
                        Text(verbatim: "Test Save and Rebuild")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("virtual_display_edit_save_and_rebuild_test_button")
                }

                Spacer()

                switch EditVirtualDisplayWorkflow.actionLayout(isRunning: isRunning) {
                case .stopped:
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("virtual_display_edit_cancel_button")

                        Button("Save") {
                            handleSaveOnlyTapped()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaveBlockedByMissingRequiredFields)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("virtual_display_edit_save_button")
                    }
                case .running:
                    HStack(spacing: 8) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("virtual_display_edit_cancel_button")

                        Button("Save Only") {
                            handleSaveOnlyTapped()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaveBlockedByMissingRequiredFields || isSaveAndRebuildInFlight)
                        .accessibilityIdentifier("virtual_display_edit_save_only_button")
                    }

                    Button("Save and Rebuild Now") {
                        handleSaveAndRebuildTapped()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaveBlockedByMissingRequiredFields || isSaveAndRebuildInFlight)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("virtual_display_edit_save_and_rebuild_button")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .appMaterialBarStyle()
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
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                                .foregroundStyle($mode.enableHiDPI.wrappedValue ? .green : .secondary)
                            Toggle("", isOn: $mode.enableHiDPI)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("virtual_display_edit_mode_hidpi_toggle")
                        }
                        ResolutionModeActionButton(
                            "Delete Resolution Mode",
                            systemImage: "minus.circle.fill",
                            tint: .red
                        ) {
                            removeMode(mode)
                        }
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

                        ResolutionModeActionButton(
                            "Add Preset Resolution",
                            systemImage: "plus.circle.fill",
                            tint: .green,
                            action: addPresetMode
                        )
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
                            .foregroundStyle(.secondary)

                        TextField("Height", value: $customHeight, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .controlSize(.small)

                        Text("@")
                            .foregroundStyle(.secondary)

                        TextField("Hz", value: $customRefreshRate, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .controlSize(.small)

                        Text("Hz")
                            .foregroundStyle(.secondary)

                        ResolutionModeActionButton(
                            "Add Custom Resolution",
                            systemImage: "plus.circle.fill",
                            tint: .green,
                            action: addCustomMode
                        )
                    }
                }
            }
        } header: {
            Text("Resolution Modes")
        } footer: {
            Text("Each resolution can enable HiDPI; when enabled, a 2× physical-pixel mode is generated automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() {
        switch EditVirtualDisplayWorkflow.load(configId: configId, virtualDisplay: virtualDisplay) {
        case .loaded(let config):
            loadedConfig = config
            populateForm(with: config)
        case .missingConfig(let alert):
            localAlert = alert
        }
    }

    private func populateForm(with config: VirtualDisplayConfig) {
        name = config.displayName
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
            localAlert = UserFacingAlertState(
                title: String(localized: "Error"),
                message: message
            )
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
        guard analysis.requiresSaveAndRebuild else {
            performSaveOnly(analysis)
            return
        }
        guard !isSaveAndRebuildInFlight else { return }
        isSaveAndRebuildInFlight = true
        Task {
            await performSaveAndRebuild(analysis)
            isSaveAndRebuildInFlight = false
        }
    }

    private func performSaveOnly(_ analysis: VirtualDisplayEditSaveAnalyzer.SaveAnalysis) {
        do {
            try virtualDisplay.updateConfig(analysis.updatedConfig)
        } catch { return }
        loadedConfig = analysis.updatedConfig
        if analysis.shouldApplyModesImmediately {
            virtualDisplay.applyModes(configId: configId, modes: selectedModes)
        }
        dismiss()
    }

    private func performSaveAndRebuild(_ analysis: VirtualDisplayEditSaveAnalyzer.SaveAnalysis) async {
        guard let loadedConfig else { return }
        do {
            let handle = try await virtualDisplay.saveConfigAndRebuild(
                analysis.updatedConfig,
                expectedConfigFingerprint: loadedConfig.editRebuildFingerprint,
                source: .editSaveAndRebuild
            )
            _ = try await handle.waitForSaveGate()
            self.loadedConfig = analysis.updatedConfig
            dismiss()
            virtualDisplay.startEditRebuildPresentation(configId: configId, handle: handle)
        } catch {
            localAlert = UserFacingAlertState(
                title: String(localized: "Save Failed"),
                message: AppErrorMapper.userMessage(
                    for: error,
                    fallback: String(localized: "Failed to save display settings.")
                )
            )
            return
        }
    }

    private func addPresetMode() {
        switch CreateVirtualDisplayInputValidator.addPresetMode(preset: presetResolution, to: selectedModes) {
        case .appended(let updated):
            selectedModes = updated
        case .duplicate:
            localAlert = UserFacingAlertState(
                title: String(localized: "Tip"),
                message: String(localized: "This resolution mode already exists.")
            )
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
            localAlert = UserFacingAlertState(
                title: String(localized: "Tip"),
                message: String(localized: "This resolution mode already exists.")
            )
        case .invalidValues:
            localAlert = UserFacingAlertState(
                title: String(localized: "Error"),
                message: String(localized: "Please enter valid resolution values.")
            )
        }
    }

    private func removeMode(_ mode: ResolutionSelection) {
        selectedModes.removeAll { $0.id == mode.id }
    }

    private func handleUITestSaveAndRebuildTapped() {
        guard isRunning else { return }
        guard let analysis = analyzeSave(reportErrors: true) else { return }
        guard !isSaveAndRebuildInFlight else { return }

        var updatedConfig = analysis.updatedConfig
        updatedConfig.physicalWidth += 1
        let forcedAnalysis = VirtualDisplayEditSaveAnalyzer.SaveAnalysis(
            updatedConfig: updatedConfig,
            shouldApplyModesImmediately: false,
            requiresSaveAndRebuild: true
        )

        isSaveAndRebuildInFlight = true
        Task {
            await performSaveAndRebuild(forcedAnalysis)
            isSaveAndRebuildInFlight = false
        }
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
