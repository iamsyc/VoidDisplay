//
//  creatVirtualDisplay.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import Cocoa
import CoreGraphics

struct CreateVirtualDisplay: View {
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
    @State private var presetResolution: Resolutions = .r_1920_1080
    @State private var customWidth: Int = 1920
    @State private var customHeight: Int = 1080
    @State private var customRefreshRate: Double = 60.0
    
    // Validation & alerts
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showDuplicateWarning = false
    
    // Focus state
    private enum FocusField: Hashable {
        case name
        case serialNum
        case screenDiagonal
        case customWidth
        case customHeight
        case customRefreshRate
    }
    @FocusState private var focusedField: FocusField?
    
    @Binding var isShow: Bool
    @EnvironmentObject var appHelper: AppHelper

    private func dismissFocus() {
        focusedField = nil
        NSApp.sendAction(#selector(NSResponder.resignFirstResponder), to: nil, from: nil)
        (NSApp.keyWindow ?? NSApp.mainWindow)?.makeFirstResponder(nil)
    }

    private struct ResignFocusOnMouseDown: NSViewRepresentable {
        var isEnabled: Bool
        var onResign: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(isEnabled: isEnabled, onResign: onResign)
        }

        func makeNSView(context: Context) -> NSView {
            NSView(frame: .zero)
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            context.coordinator.isEnabled = isEnabled
            context.coordinator.onResign = onResign
            context.coordinator.updateMonitor()
        }

        static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
            coordinator.stop()
        }

        final class Coordinator {
            var isEnabled: Bool
            var onResign: () -> Void
            private var monitor: Any?

            init(isEnabled: Bool, onResign: @escaping () -> Void) {
                self.isEnabled = isEnabled
                self.onResign = onResign
            }

            func updateMonitor() {
                if isEnabled {
                    startIfNeeded()
                } else {
                    stop()
                }
            }

            private func startIfNeeded() {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                    self?.handle(event)
                    return event
                }
            }

            func stop() {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }

            private func handle(_ event: NSEvent) {
                guard isEnabled else { return }
                guard let window = event.window else { return }
                guard let contentView = window.contentView else {
                    onResign()
                    return
                }

                let pointInContent = contentView.convert(event.locationInWindow, from: nil)
                let hitView = contentView.hitTest(pointInContent)
                if isTextInputView(hitView) {
                    return
                }
                onResign()
            }

            private func isTextInputView(_ view: NSView?) -> Bool {
                var current = view
                while let v = current {
                    if v is NSTextView || v is NSTextField {
                        return true
                    }
                    current = v.superview
                }
                return false
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var physicalSize: (width: Int, height: Int) {
        selectedAspectRatio.sizeInMillimeters(diagonalInches: screenDiagonal)
    }
    
    private var maxPixelDimensions: (width: UInt32, height: UInt32) {
        guard let maxMode = selectedModes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
            return (1920, 1080)
        }
        // Check if any mode has HiDPI enabled
        let anyHiDPI = selectedModes.contains { $0.enableHiDPI }
        if anyHiDPI {
            return (UInt32(maxMode.width * 2), UInt32(maxMode.height * 2))
        }
        return (UInt32(maxMode.width), UInt32(maxMode.height))
    }
    
    private var aspectPreviewRatio: CGFloat {
        let components = selectedAspectRatio.components
        return CGFloat(components.width / components.height)
    }
    
    // MARK: - Body
    
    var body: some View {
        Form {
            // Basic Info Section
            Section {
                TextField("Name", text: $name)
                    .focused($focusedField, equals: .name)
                
                HStack {
                    Text("Serial Number")
                    Spacer()
                    if customSerialNum {
                        TextField("", value: $serialNum, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .focused($focusedField, equals: .serialNum)
                    } else {
                        Text(serialNum, format: .number)
                            .foregroundColor(.secondary)
                    }
                }
                
                Toggle("Custom Serial Number", isOn: $customSerialNum)
            } header: {
                Text("Basic Info")
            }
            
            // Physical Display Section
            Section {
                HStack {
                    Text("Screen Size")
                    Spacer()
                    TextField("", value: $screenDiagonal, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .screenDiagonal)
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
                    Text("\(physicalSize.width) × \(physicalSize.height) mm")
                        .foregroundColor(.secondary)
                }
                
                // Aspect ratio preview
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
                                if mode.enableHiDPI {
                                    Text("HiDPI Enabled")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: $mode.enableHiDPI)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .scaleEffect(0.8)
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
                        // Preset mode
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
                        // Custom mode
                        HStack {
                            TextField("Width", value: $customWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .focused($focusedField, equals: .customWidth)
                            Text("×")
                            TextField("Height", value: $customHeight, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .focused($focusedField, equals: .customHeight)
                            Text("@")
                            TextField("Hz", value: $customRefreshRate, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .focused($focusedField, equals: .customRefreshRate)
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
                Text("Each resolution can enable HiDPI; when enabled, a 2× physical-pixel mode is generated automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .background(ResignFocusOnMouseDown(isEnabled: focusedField != nil, onResign: dismissFocus))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    dismissFocus()
                    createDisplayAction()
                }
                .disabled(selectedModes.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismissFocus()
                    isShow = false
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .alert("Tip", isPresented: $showDuplicateWarning) {
            Button("OK") {}
        } message: {
            Text("This resolution mode already exists.")
        }
        .onAppear {
            serialNum = appHelper.nextAvailableSerialNumber()
            focusedField = .name
            // Add a default mode
            if selectedModes.isEmpty {
                selectedModes.append(ResolutionSelection(preset: .r_1920_1080))
            }
        }
    }
    
    // MARK: - Actions
    
    private func addPresetMode() {
        let newMode = ResolutionSelection(preset: presetResolution)  // HiDPI defaults to true
        if selectedModes.contains(newMode) {
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
        let newMode = ResolutionSelection(width: customWidth, height: customHeight, refreshRate: customRefreshRate)  // HiDPI defaults to true
        if selectedModes.contains(newMode) {
            showDuplicateWarning = true
        } else {
            selectedModes.append(newMode)
        }
    }
    
    private func removeMode(_ mode: ResolutionSelection) {
        selectedModes.removeAll { $0 == mode }
    }
    
    private func createDisplayAction() {
        let size = physicalSize
        
        do {
            _ = try appHelper.createDisplay(
                name: name,
                serialNum: serialNum,
                physicalSize: CGSize(width: size.width, height: size.height),
                maxPixels: maxPixelDimensions,
                modes: selectedModes
            )
            isShow = false
        } catch let error as AppHelper.VirtualDisplayError {
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = String(localized: "Create failed: \(error.localizedDescription)")
            showError = true
        }
    }
}

#Preview {
//    CreateVirtualDisplay(isShow: .constant(true))
}
