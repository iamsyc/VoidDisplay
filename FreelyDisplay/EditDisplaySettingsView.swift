//
//  EditDisplaySettingsView.swift
//  FreelyDisplay
//
//  Edit settings for an existing virtual display
//

import SwiftUI
import CoreGraphics

struct EditDisplaySettingsView: View {
    let display: CGVirtualDisplay
    @Binding var isShow: Bool
    
    // Editable settings
    @State private var selectedResolution: Resolutions = .r_1920_1080
    @State private var enableHiDPI: Bool = true
    
    @EnvironmentObject var appHelper: AppHelper
    
    // Computed properties
    private var logicalResolution: (width: Int, height: Int) {
        selectedResolution.resolutions
    }
    
    private var physicalPixels: (width: Int, height: Int) {
        DisplayCalculator.physicalPixels(
            logicalWidth: logicalResolution.width,
            logicalHeight: logicalResolution.height,
            hiDPI: enableHiDPI
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Display Info (Read-only)
            GroupBox(label: Text("Display Info").font(.headline)) {
                VStack(spacing: 12) {
                    HStack {
                        Text("Name")
                            .frame(width: 120, alignment: .leading)
                        Text(display.name)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    HStack {
                        Text("Serial Number")
                            .frame(width: 120, alignment: .leading)
                        Text(String(display.serialNum))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    HStack {
                        Text("Physical Size")
                            .frame(width: 120, alignment: .leading)
                        Text("\(Int(display.sizeInMillimeters.width)) × \(Int(display.sizeInMillimeters.height)) mm")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 8)
            }
            
            // Editable Settings
            GroupBox(label: Text("Display Settings").font(.headline)) {
                VStack(spacing: 12) {
                    HStack {
                        Text("Logical Resolution")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $selectedResolution) {
                            ForEach(Resolutions.allCases) { res in
                                Text("\(res.resolutions.0) × \(res.resolutions.1)")
                                    .tag(res)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Spacer()
                    }
                    
                    HStack {
                        Text("")
                            .frame(width: 120, alignment: .leading)
                        Toggle("Enable HiDPI (Retina)", isOn: $enableHiDPI)
                        Spacer()
                    }
                    
                    HStack {
                        Text("Physical Pixels")
                            .frame(width: 120, alignment: .leading)
                        Text("\(physicalPixels.width) × \(physicalPixels.height)")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 8)
            }
            
            Spacer()
        }
        .padding(20)
        .frame(width: 450, height: 380)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    applySettings()
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    isShow = false
                }
            }
        }
        .onAppear {
            // Try to detect current settings from display
            enableHiDPI = display.hiDPI > 0
        }
    }
    
    private func applySettings() {
        let (logicalWidth, logicalHeight) = logicalResolution
        let (physWidth, physHeight) = physicalPixels
        
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = enableHiDPI ? 1 : 0
        
        // Build modes array
        var modes: [CGVirtualDisplayMode] = []
        
        if enableHiDPI {
            // HiDPI mode: physical pixels = logical × 2
            modes.append(CGVirtualDisplayMode(
                width: UInt(physWidth),
                height: UInt(physHeight),
                refreshRate: 60
            ))
        }
        
        // Always include standard mode (logical resolution)
        modes.append(CGVirtualDisplayMode(
            width: UInt(logicalWidth),
            height: UInt(logicalHeight),
            refreshRate: 60
        ))
        
        settings.modes = modes
        
        // Apply settings to existing display
        display.apply(settings)
        
        // Refresh the display list
        appHelper.id = UUID()
        
        isShow = false
    }
}
