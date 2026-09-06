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
    @FocusState private var focusedField: VirtualDisplayConfigurationFocusField?

    package init(configId: UUID) {
        self.configId = configId
    }

    private var isRunning: Bool {
        virtualDisplay.isVirtualDisplayRunning(configId: configId)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSaveBlockedByMissingRequiredFields: Bool {
        trimmedName.isEmpty || selectedModes.isEmpty
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
            VirtualDisplayPhysicalConfigurationSection(
                screenDiagonal: $screenDiagonal,
                selectedAspectRatio: $selectedAspectRatio,
                physicalSizeText: displayedPhysicalSizeText,
                focusedField: $focusedField
            )
            VirtualDisplayResolutionModesSection(
                selectedModes: $selectedModes,
                usePresetMode: $usePresetMode,
                presetResolution: $presetResolution,
                customWidth: $customWidth,
                customHeight: $customHeight,
                customRefreshRate: $customRefreshRate,
                alert: $localAlert,
                focusedField: $focusedField,
                hiDPIAccessibilityIdentifier: "virtual_display_edit_mode_hidpi_toggle"
            )
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .interactiveDismissDisabled(isSaveAndRebuildInFlight)
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
                Spacer()

                switch EditVirtualDisplayWorkflow.actionLayout(isRunning: isRunning) {
                case .stopped:
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaveAndRebuildInFlight)
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
                        .disabled(isSaveAndRebuildInFlight)
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
                .focused($focusedField, equals: .name)
                .accessibilityIdentifier("virtual_display_edit_name_field")

            HStack {
                Text("Serial Number")
                Spacer()
                TextField("Serial Number", value: $serialNum, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .focused($focusedField, equals: .serialNumber)
                    .accessibilityIdentifier("virtual_display_edit_serial_field")
            }

            if isRunning {
                Text("Save Only keeps the running display unchanged. Save and Rebuild Now applies these settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Basic Info")
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

    private func analyzeSave() -> VirtualDisplayConfig? {
        let result = VirtualDisplayEditSaveAnalyzer.analyze(
            original: loadedConfig,
            configId: configId,
            draft: saveDraft,
            existingConfigs: virtualDisplay.displayConfigs
        )

        switch result {
        case .success(let updatedConfig):
            return updatedConfig
        case .failure(let error):
            guard let message = validationErrorMessage(error) else { return nil }
            localAlert = UserFacingAlertState(
                title: String(localized: "Error"),
                message: message
            )
            return nil
        }
    }

    private func handleSaveOnlyTapped() {
        guard let updatedConfig = analyzeSave() else { return }
        performSaveOnly(updatedConfig)
    }

    private func handleSaveAndRebuildTapped() {
        guard isRunning else { return }
        guard let updatedConfig = analyzeSave() else { return }
        guard !isSaveAndRebuildInFlight else { return }
        isSaveAndRebuildInFlight = true
        Task {
            await performSaveAndRebuild(updatedConfig)
            isSaveAndRebuildInFlight = false
        }
    }

    private func performSaveOnly(_ updatedConfig: VirtualDisplayConfig) {
        do {
            try virtualDisplay.updateConfig(updatedConfig)
        } catch { return }
        loadedConfig = updatedConfig
        dismiss()
    }

    private func performSaveAndRebuild(_ updatedConfig: VirtualDisplayConfig) async {
        guard let loadedConfig else { return }
        do {
            let operation = try await virtualDisplay.saveConfigAndRebuild(
                updatedConfig,
                expectedConfigFingerprint: loadedConfig.editRebuildFingerprint,
                source: .editSaveAndRebuild
            )
            try await operation.waitForSave()
            self.loadedConfig = updatedConfig
            dismiss()
            virtualDisplay.startEditRebuildPresentation(configId: configId, operation: operation)
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
