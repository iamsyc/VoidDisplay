//
//  FreelyDisplayApp.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import Combine
import ScreenCaptureKit
import Network

//var sceneCapture:SceneCapture?
@main
struct FreelyDisplayApp: App {
//    @StateObject var captureOutput=Capture()
    
    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(AppHelper.shared)
                
                .id(AppHelper.shared.id)
//                .onAppear{
//                    Task{
//                        let content = try? await SCShareableContent.excludingDesktopWindows(
//                            false,
//                            onScreenWindowsOnly: true
//                        )
//                        guard let displays = content?.displays else { return }
//                        sceneCapture=await SceneCapture(display: displays.first!, output: captureOutput)
//                    }
//                }
        }
        
        WindowGroup(for: Int.self){$index in
            @Environment(\.dismiss) var dismiss
            let caputure=Capture()
            if let index = index{
                if AppHelper.shared.screenCaptureObjects.count > index{
                    CaptureDisplayView(index: index)
                        .navigationTitle("Screen Monitoring")
                        .environmentObject(caputure)
                        .environmentObject(AppHelper.shared)
                }else{Group{}.onAppear{
                    dismiss()
                }}
            }
            
                
        }
        
        
        
        
    }
    
}

class AppHelper:ObservableObject{
    @Published var displays:[CGVirtualDisplay]=[]
    static var shared=AppHelper()
    @Published var id=UUID()
    @Published var screenCaptureObjects:[SCStream?]=[]
    @Published var sharingScreenCaptureObject:SCStream?=nil
    @Published var sharingScreenCaptureStream:Capture?=nil
    @Published var isSharing=false
    let webServer=try? WebServer(using: 8081)
    init() {
        webServer?.startListener()
    }
    
    // MARK: - Virtual Display Creation
    
    /// Error types for virtual display creation
    enum VirtualDisplayError: LocalizedError {
        case duplicateSerialNumber(UInt32)
        case invalidConfiguration(String)
        case creationFailed
        
        var errorDescription: String? {
            switch self {
            case .duplicateSerialNumber(let num):
                return "序列号 \(num) 已被使用"
            case .invalidConfiguration(let reason):
                return "配置无效: \(reason)"
            case .creationFailed:
                return "创建虚拟显示器失败"
            }
        }
    }
    
    /// Creates a new virtual display with the specified configuration
    /// - Parameters:
    ///   - name: Display name
    ///   - serialNum: Unique serial number
    ///   - physicalSize: Physical size in millimeters
    ///   - maxPixels: Maximum supported pixel dimensions
    ///   - modes: Array of resolution modes to support (each with its own HiDPI setting)
    /// - Returns: The created CGVirtualDisplay
    /// - Throws: VirtualDisplayError if creation fails
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> CGVirtualDisplay {
        // Check for duplicate serial number
        if displays.contains(where: { $0.serialNum == serialNum }) {
            throw VirtualDisplayError.duplicateSerialNumber(serialNum)
        }
        
        // Validate modes
        guard !modes.isEmpty else {
            throw VirtualDisplayError.invalidConfiguration("至少需要一个分辨率模式")
        }
        
        // Configure descriptor
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.terminationHandler = { _, display in
            NSLog("Virtual display terminated: \(String(describing: display))")
        }
        desc.name = name
        desc.maxPixelsWide = maxPixels.width
        desc.maxPixelsHigh = maxPixels.height
        desc.sizeInMillimeters = physicalSize
        desc.productID = 0x1234
        desc.vendorID = 0x3456
        desc.serialNum = serialNum
        
        // Create display
        let display = CGVirtualDisplay(descriptor: desc)
        
        // Configure settings
        let settings = CGVirtualDisplaySettings()
        
        // Enable HiDPI if any mode has HiDPI enabled
        let anyHiDPI = modes.contains { $0.enableHiDPI }
        settings.hiDPI = anyHiDPI ? 1 : 0
        
        // Build modes array
        var displayModes: [CGVirtualDisplayMode] = []
        
        for mode in modes {
            if mode.enableHiDPI {
                // Add HiDPI version first (physical pixels = logical × 2)
                let hiDPIMode = mode.hiDPIVersion()
                displayModes.append(hiDPIMode.toVirtualDisplayMode())
            }
            // Add standard mode
            displayModes.append(mode.toVirtualDisplayMode())
        }
        
        settings.modes = displayModes
        display.apply(settings)
        
        // Add to managed displays
        displays.append(display)
        
        return display
    }
    
    /// Generates the next available serial number
    func nextAvailableSerialNumber() -> UInt32 {
        let usedNumbers = Set(displays.map { $0.serialNum })
        var next: UInt32 = 1
        while usedNumbers.contains(next) {
            next += 1
        }
        return next
    }
}


