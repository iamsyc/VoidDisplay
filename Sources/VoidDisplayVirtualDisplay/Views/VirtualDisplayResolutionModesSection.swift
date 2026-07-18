import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability

package struct VirtualDisplayResolutionModesSection: View {
    @Binding private var selectedModes: [ResolutionSelection]
    @Binding private var usePresetMode: Bool
    @Binding private var presetResolution: DisplayResolutionPreset
    @Binding private var customWidth: Int
    @Binding private var customHeight: Int
    @Binding private var customRefreshRate: Double
    @Binding private var alert: UserFacingAlertState?

    private let focusedField: FocusState<VirtualDisplayConfigurationFocusField?>.Binding
    private let hiDPIAccessibilityIdentifier: String
    private let onInputChange: () -> Void

    package init(
        selectedModes: Binding<[ResolutionSelection]>,
        usePresetMode: Binding<Bool>,
        presetResolution: Binding<DisplayResolutionPreset>,
        customWidth: Binding<Int>,
        customHeight: Binding<Int>,
        customRefreshRate: Binding<Double>,
        alert: Binding<UserFacingAlertState?>,
        focusedField: FocusState<VirtualDisplayConfigurationFocusField?>.Binding,
        hiDPIAccessibilityIdentifier: String,
        onInputChange: @escaping () -> Void = {}
    ) {
        _selectedModes = selectedModes
        _usePresetMode = usePresetMode
        _presetResolution = presetResolution
        _customWidth = customWidth
        _customHeight = customHeight
        _customRefreshRate = customRefreshRate
        _alert = alert
        self.focusedField = focusedField
        self.hiDPIAccessibilityIdentifier = hiDPIAccessibilityIdentifier
        self.onInputChange = onInputChange
    }

    package var body: some View {
        Section {
            modeList
            Divider()
            addMethodPicker
            addModeControls
        } header: {
            Text("Resolution Modes")
        } footer: {
            Text("Each resolution can enable HiDPI; when enabled, a 2× physical-pixel mode is generated automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var modeList: some View {
        if selectedModes.isEmpty {
            Text("No resolution modes added")
                .foregroundStyle(.secondary)
                .italic()
        } else {
            ForEach($selectedModes) { $mode in
                HStack {
                    Text(verbatim: "\(mode.width) × \(mode.height) @ \(Int(mode.refreshRate))Hz")
                    Spacer()
                    HStack(spacing: 6) {
                        Text("HiDPI")
                            .font(.caption)
                            .foregroundStyle(mode.enableHiDPI ? .green : .secondary)
                        Toggle("HiDPI", isOn: $mode.enableHiDPI)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .accessibilityIdentifier(hiDPIAccessibilityIdentifier)
                    }
                    .onChange(of: mode.enableHiDPI) { _, _ in
                        onInputChange()
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
    }

    private var addMethodPicker: some View {
        Picker("Add Method", selection: $usePresetMode) {
            Text("Preset").tag(true)
            Text("Custom").tag(false)
        }
        .pickerStyle(.segmented)
        .onChange(of: usePresetMode) { _, _ in
            onInputChange()
        }
    }

    @ViewBuilder
    private var addModeControls: some View {
        if usePresetMode {
            LabeledContent(String(localized: "Preset")) {
                HStack(spacing: 8) {
                    Picker("Preset Resolution", selection: $presetResolution) {
                        ForEach(DisplayResolutionPreset.allCases) { resolution in
                            Text(verbatim: "\(resolution.displayText) @ 60Hz")
                                .tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: presetResolution) { _, _ in
                        onInputChange()
                    }

                    ResolutionModeActionButton(
                        "Add Preset Resolution",
                        systemImage: "plus.circle.fill",
                        tint: .green
                    ) {
                        onInputChange()
                        addPresetMode()
                    }
                }
            }
        } else {
            customModeControls
        }
    }

    private var customModeControls: some View {
        LabeledContent(String(localized: "Custom")) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                resolutionField("Width", value: $customWidth, width: 70, focus: .customWidth)
                Text("×")
                    .foregroundStyle(.secondary)
                resolutionField("Height", value: $customHeight, width: 70, focus: .customHeight)
                Text("@")
                    .foregroundStyle(.secondary)
                TextField("Hz", value: $customRefreshRate, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .focused(focusedField, equals: .customRefreshRate)
                    .monospacedDigit()
                    .controlSize(.small)
                Text("Hz")
                    .foregroundStyle(.secondary)
                ResolutionModeActionButton(
                    "Add Custom Resolution",
                    systemImage: "plus.circle.fill",
                    tint: .green
                ) {
                    onInputChange()
                    addCustomMode()
                }
            }
        }
    }

    private func resolutionField(
        _ title: LocalizedStringKey,
        value: Binding<Int>,
        width: CGFloat,
        focus: VirtualDisplayConfigurationFocusField
    ) -> some View {
        TextField(title, value: value, format: .number)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(.trailing)
            .focused(focusedField, equals: focus)
            .monospacedDigit()
            .controlSize(.small)
    }

    private func addPresetMode() {
        switch CreateVirtualDisplayInputValidator.addPresetMode(
            preset: presetResolution,
            to: selectedModes
        ) {
        case .appended(let updated):
            selectedModes = updated
        case .duplicate:
            presentDuplicateAlert()
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
            presentDuplicateAlert()
        case .invalidValues:
            alert = UserFacingAlertState(
                title: String(localized: "Error"),
                message: String(localized: "Please enter valid resolution values.")
            )
        }
    }

    private func presentDuplicateAlert() {
        alert = UserFacingAlertState(
            title: String(localized: "Tip"),
            message: String(localized: "This resolution mode already exists.")
        )
    }

    private func removeMode(_ mode: ResolutionSelection) {
        selectedModes.removeAll { $0.id == mode.id }
    }
}
