//
//  CreateVirtualDisplayObjectView.swift
//  VoidDisplay
//
//

import CoreGraphics
import Foundation
import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayFoundation

package struct CreateVirtualDisplay: View {
    // MARK: - State Properties
    
    // Basic info
    @State private var name = ""
    @State private var selectedTemplate = VirtualDisplayCreationTemplate.presentation
    @State private var showsAdvancedSettings = false
    @State private var shouldOpenPreview = true
    @State private var serialNum: UInt32 = 1
    @State private var customSerialNum = false
    
    // Physical display
    @State private var screenDiagonal: Double = 14.0
    @State private var selectedAspectRatio: AspectRatio = .ratio_16_9
    
    // Resolution modes
    @State private var selectedModes: [ResolutionSelection] = [.init(preset: .w1920h1080, enableHiDPI: false)]
    
    // Mode input
    @State private var usePresetMode = true
    @State private var presetResolution: DisplayResolutionPreset = .w1920h1080
    @State private var customWidth: Int = 1920
    @State private var customHeight: Int = 1080
    @State private var customRefreshRate: Double = 60.0
    
    // Validation & alerts
    @State private var localAlert: UserFacingAlertState?
    @State private var isCreating = false
    
    // Focus state
    @FocusState private var focusedField: VirtualDisplayConfigurationFocusField?
    
    @Binding var isShow: Bool
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    private let onCreated: @MainActor (CreatedDisplayOutcome) -> Void

    package init(isShow: Binding<Bool>, onCreated: @escaping @MainActor (CreatedDisplayOutcome) -> Void) {
        _isShow = isShow
        self.onCreated = onCreated
    }

    private func clearFocus() {
        focusedField = nil
    }

    // MARK: - Computed Properties
    
    private var physicalSize: (width: Int, height: Int) {
        selectedAspectRatio.sizeInMillimeters(diagonalInches: screenDiagonal)
    }
    
    private var maxPixelDimensions: CreateVirtualDisplayInputValidator.MaxPixelDimensionsResult {
        CreateVirtualDisplayInputValidator.maxPixelDimensions(for: selectedModes)
    }
    
    // MARK: - Body
    
    package var body: some View {
        @Bindable var bindableVirtualDisplay = virtualDisplay

        Form {
            Section {
                Picker("Use", selection: $selectedTemplate) {
                    ForEach(VirtualDisplayCreationTemplate.allCases) { template in
                        Text(template.title).tag(template)
                    }
                }
                .accessibilityIdentifier("virtual_display_creation_template_picker")
                .onChange(of: selectedTemplate) { previous, selected in
                    name = selected.replacingName(name, from: previous, serial: serialNum)
                    if let modes = selected.modes {
                        selectedModes = modes
                        screenDiagonal = 14
                        selectedAspectRatio = .ratio_16_9
                    } else {
                        showsAdvancedSettings = true
                    }
                    clearFocus()
                }
                Text("Choosing a template replaces the resolution and physical size. Your edited name is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(selectedModes) { mode in
                    LabeledContent("Workspace", value: "\(mode.width) × \(mode.height) · \(Int(mode.refreshRate)) Hz")
                    if case .resolved(let width, let height) = CreateVirtualDisplayInputValidator.maxPixelDimensions(for: [mode]) {
                        LabeledContent("Native Pixels", value: "\(width) × \(height)")
                    }
                }
            }
            basicInfoSection
            Section {
                Toggle("Open preview after creating", isOn: $shouldOpenPreview)
                    .accessibilityIdentifier("virtual_display_create_preview_toggle")
                Toggle("Advanced Settings", isOn: $showsAdvancedSettings)
                    .accessibilityIdentifier("virtual_display_create_advanced_toggle")
            }
            if showsAdvancedSettings {
                serialSection
                VirtualDisplayPhysicalConfigurationSection(
                    screenDiagonal: $screenDiagonal,
                    selectedAspectRatio: $selectedAspectRatio,
                    physicalSizeText: "\(physicalSize.width) × \(physicalSize.height) mm",
                    focusedField: $focusedField,
                    onAspectRatioChange: clearFocus
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
                    hiDPIAccessibilityIdentifier: "virtual_display_create_mode_hidpi_toggle",
                    onInputChange: clearFocus
                )
            }
        }
        .formStyle(.grouped)
        .disabled(isCreating)
        .frame(width: 480, height: 580)
        .accessibilityIdentifier("virtual_display_create_form")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(shouldOpenPreview ? String(localized: "Create and Preview") : String(localized: "Create")) {
                    clearFocus()
                    Task {
                        await createDisplayAction()
                    }
                }
                .disabled(isCreating || selectedModes.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("virtual_display_create_button")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    clearFocus()
                    isShow = false
                }
                .disabled(isCreating)
                .accessibilityIdentifier("virtual_display_create_cancel_button")
            }
        }
        .interactiveDismissDisabled(isCreating)
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
            guard name.isEmpty else { return }
            serialNum = virtualDisplay.nextAvailableSerialNumber()
            name = selectedTemplate.defaultName(serial: serialNum)
            focusedField = .name
        }
    }
    
    @ViewBuilder
    private var basicInfoSection: some View {
        Section {
            TextField("Name", text: $name)
                .focused($focusedField, equals: .name)
        } header: {
            Text("Basic Info")
        }
    }

    private var serialSection: some View {
        Section {
            HStack {
                Text("Serial Number")
                Spacer()
                if customSerialNum {
                    TextField("Serial Number", value: $serialNum, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .serialNumber)
                } else {
                    Text(serialNum, format: .number)
                        .foregroundStyle(.secondary)
                }
            }
            
            Toggle("Custom Serial Number", isOn: $customSerialNum)
                .accessibilityIdentifier("virtual_display_create_custom_serial_toggle")
        } header: {
            Text("Basic Info")
        }
    }
    
    private func createDisplayAction() async {
        guard !isCreating else { return }
        let size = physicalSize
        guard case .resolved(let maxPixelWidth, let maxPixelHeight) = maxPixelDimensions else {
            localAlert = UserFacingAlertState(
                title: String(localized: "Error"),
                message: String(localized: "Please enter valid resolution values.")
            )
            return
        }
        
        isCreating = true
        defer { isCreating = false }
        do {
            let configID = try await virtualDisplay.createVirtualDisplay(
                VirtualDisplayCreateRequest(
                    displayName: name,
                    serialNumber: serialNum,
                    physicalWidthMillimeters: UInt32(clamping: size.width),
                    physicalHeightMillimeters: UInt32(clamping: size.height),
                    maximumPixelWidth: maxPixelWidth,
                    maximumPixelHeight: maxPixelHeight,
                    modes: selectedModes
                )
            )
            isShow = false
            onCreated(.init(configID: configID, shouldOpenPreview: shouldOpenPreview))
        } catch {}
    }
}
