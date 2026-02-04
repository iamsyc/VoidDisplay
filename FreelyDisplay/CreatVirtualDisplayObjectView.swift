//
//  creatVirtualDisplay.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import Cocoa
import CoreGraphics

struct creatVirtualDisplay: View {
    @State var name = "Virtual Display"
    @State var serialNum = 1
    @Binding var isShow: Bool
    @State var serialNumError = false
    @State var customSerialNumError = false
    
    // Flexible display configuration
    @State var screenDiagonal: Double = 14.0          // Screen size in inches
    @State var selectedAspectRatio: AspectRatio = .ratio_16_9
    @State var selectedResolution: Resolutions = .r_1920_1080
    @State var enableHiDPI: Bool = true               // HiDPI toggle
    
    @EnvironmentObject var appHelper: AppHelper
    
    // Computed properties for display info
    private var physicalSize: (width: Int, height: Int) {
        selectedAspectRatio.sizeInMillimeters(diagonalInches: screenDiagonal)
    }
    
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
    
    private var calculatedPPI: Double {
        DisplayCalculator.calculatePPI(
            widthPixels: physicalPixels.width,
            heightPixels: physicalPixels.height,
            diagonalInches: screenDiagonal
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Basic Info Section
            GroupBox(label: Text("Basic Info").font(.headline)) {
                VStack(spacing: 12) {
                    HStack {
                        Text("Name")
                            .frame(width: 120, alignment: .leading)
                        TextField("Virtual Display", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Serial Number")
                            .frame(width: 120, alignment: .leading)
                        TextField("", value: $serialNum, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!customSerialNumError)
                    }
                    Toggle("Custom Serial Number", isOn: $customSerialNumError)
                        .padding(.leading, 120)
                }
                .padding(8)
            }
            
            // Physical Display Section
            GroupBox(label: Text("Physical Display").font(.headline)) {
                VStack(spacing: 12) {
                    HStack {
                        Text("Screen Size")
                            .frame(width: 120, alignment: .leading)
                        TextField("", value: $screenDiagonal, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("inches")
                        Spacer()
                    }
                    
                    HStack {
                        Text("Aspect Ratio")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $selectedAspectRatio) {
                            ForEach(AspectRatio.allCases) { ratio in
                                Text(ratio.rawValue).tag(ratio)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Spacer()
                    }
                    
                    HStack {
                        Text("Physical Size")
                            .frame(width: 120, alignment: .leading)
                        Text("\(physicalSize.width) × \(physicalSize.height) mm")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(8)
            }
            
            // Resolution Section
            GroupBox(label: Text("Resolution").font(.headline)) {
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
                    
                    Toggle("Enable HiDPI (Retina)", isOn: $enableHiDPI)
                        .padding(.leading, 120)
                    
                    HStack {
                        Text("Physical Pixels")
                            .frame(width: 120, alignment: .leading)
                        Text("\(physicalPixels.width) × \(physicalPixels.height)")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    HStack {
                        Text("Calculated PPI")
                            .frame(width: 120, alignment: .leading)
                        Text(String(format: "%.0f", calculatedPPI))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(8)
            }
            
            Spacer()
        }
        .padding(20)
        .frame(width: 480, height: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    if appHelper.displays.filter({ Int($0.serialNum) == serialNum }).isEmpty {
                        makeVirtualDisplay()
                    } else {
                        serialNumError = true
                    }
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    isShow = false
                }
            }
        }
        .alert(Text("Error"), isPresented: $serialNumError, actions: { Button("OK") {} }, message: { Text("This serial number has already been used.") })
        .onAppear {
            let _ = appHelper.displays.map { item in
                if serialNum <= Int(item.serialNum) {
                    serialNum += 1
                }
            }
        }
    }
    
    private func makeVirtualDisplay() {
        // Get logical resolution
        let (logicalWidth, logicalHeight) = logicalResolution
        
        // Calculate physical pixels based on HiDPI setting
        let (physWidth, physHeight) = physicalPixels
        
        // Configure virtual display descriptor
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.terminationHandler = { a, b in
            NSLog("\(String(describing: a)), \(String(describing: b))")
        }
        desc.name = name
        
        // Set max pixels to support the physical resolution
        desc.maxPixelsWide = UInt32(physWidth)
        desc.maxPixelsHigh = UInt32(physHeight)
        
        // Physical size calculated from screen diagonal and aspect ratio
        let size = physicalSize
        desc.sizeInMillimeters = CGSize(width: size.width, height: size.height)
        
        desc.productID = 0x1234
        desc.vendorID = 0x3456
        desc.serialNum = UInt32(serialNum)

        let display = CGVirtualDisplay(descriptor: desc)

        // Configure display settings
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
        
        appHelper.displays.append(display)
        display.apply(settings)
        
        isShow = false
    }
}

#Preview {
//    creatVirtualDisplay(isShow: .constant(true))
}
