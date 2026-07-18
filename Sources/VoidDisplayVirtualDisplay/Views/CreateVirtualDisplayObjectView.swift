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

    package init(isShow: Binding<Bool>) {
        _isShow = isShow
    }

    private func clearFocus() {
        focusedField = nil
    }

    private var baseDisplayName: String {
        String(localized: "Virtual Display")
    }

    private func defaultName(for serial: UInt32) -> String {
        CreateVirtualDisplayInputValidator.defaultName(baseName: baseDisplayName, serialNum: serial)
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
            basicInfoSection
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
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    clearFocus()
                    Task {
                        await createDisplayAction()
                    }
                }
                .disabled(isCreating || selectedModes.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    clearFocus()
                    isShow = false
                }
                .disabled(isCreating)
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
            let initial = CreateVirtualDisplayInputValidator.initializeNameAndSerial(
                currentName: name,
                baseName: baseDisplayName,
                nextSerial: virtualDisplay.nextAvailableSerialNumber()
            )
            serialNum = initial.serialNum
            name = initial.name
            focusedField = .name
            // Add a default mode
            if selectedModes.isEmpty {
                selectedModes.append(ResolutionSelection(preset: .w1920h1080))
            }
        }
    }
    
    @ViewBuilder
    private var basicInfoSection: some View {
        Section {
            TextField("Name", text: $name)
                .focused($focusedField, equals: .name)
            
            HStack {
                Text("Serial Number")
                Spacer()
                if customSerialNum {
                    TextField("Serial Number", value: $serialNum, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .serialNumber)
                } else {
                    Text(serialNum, format: .number)
                        .foregroundStyle(.secondary)
                }
            }
            
            Toggle("Custom Serial Number", isOn: $customSerialNum)
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
            _ = try await virtualDisplay.createVirtualDisplay(
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
        } catch {}
    }
}

package struct CreateVirtualDisplayWorkflow {
    package enum Outcome: Equatable {
        case created
        case failed
        case invalidResolution
    }

    private let create: @MainActor (VirtualDisplayCreateRequest) async throws -> UUID?

    package init(create: @escaping @MainActor (VirtualDisplayCreateRequest) async throws -> UUID?) {
        self.create = create
    }

    package func submit(
        displayName: String,
        serialNumber: UInt32,
        physicalSize: (width: Int, height: Int),
        maxPixelDimensions: CreateVirtualDisplayInputValidator.MaxPixelDimensionsResult,
        modes: [ResolutionSelection]
    ) async -> Outcome {
        guard case .resolved(let maxPixelWidth, let maxPixelHeight) = maxPixelDimensions else {
            return .invalidResolution
        }
        do {
            _ = try await create(
                VirtualDisplayCreateRequest(
                    displayName: displayName,
                    serialNumber: serialNumber,
                    physicalWidthMillimeters: UInt32(clamping: physicalSize.width),
                    physicalHeightMillimeters: UInt32(clamping: physicalSize.height),
                    maximumPixelWidth: maxPixelWidth,
                    maximumPixelHeight: maxPixelHeight,
                    modes: modes
                )
            )
            return .created
        } catch {
            return .failed
        }
    }
}
