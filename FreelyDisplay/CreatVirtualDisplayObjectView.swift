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
        Form {
            // Basic Info Section
            Section {
                TextField("Name", text: $name)
                TextField("Serial Number", value: $serialNum, format: .number)
                    .disabled(!customSerialNumError)
                Toggle("Custom Serial Number", isOn: $customSerialNumError)
            }
            
            // Physical Display Section
            Section(header: Text("Physical Display")) {
                HStack {
                    Text("Screen Size")
                    Spacer()
                    TextField("Inches", value: $screenDiagonal, format: .number.precision(.fractionLength(1)))
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("inches")
                }
                
                Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                    ForEach(AspectRatio.allCases) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }
                
                // Show calculated physical dimensions
                HStack {
                    Text("Physical Size")
                    Spacer()
                    Text("\(physicalSize.width)mm × \(physicalSize.height)mm")
                        .foregroundColor(.secondary)
                }
            }
            
            // Resolution Section
            Section(header: Text("Resolution")) {
                Picker("Logical Resolution", selection: $selectedResolution) {
                    ForEach(Resolutions.allCases) { res in
                        Text("\(res.resolutions.0) × \(res.resolutions.1)")
                            .tag(res)
                    }
                }
                
                Toggle("Enable HiDPI (Retina)", isOn: $enableHiDPI)
                
                // Show physical pixels
                HStack {
                    Text("Physical Pixels")
                    Spacer()
                    Text("\(physicalPixels.width) × \(physicalPixels.height)")
                        .foregroundColor(.secondary)
                }
                
                // Show PPI
                HStack {
                    Text("Calculated PPI")
                    Spacer()
                    Text(String(format: "%.0f", calculatedPPI))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(minWidth: 400)
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
