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
    @Published var displayConfigs:[VirtualDisplayConfig]=[]  // Stores configs for all displays (enabled and disabled)
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
        case configNotFound
        
        var errorDescription: String? {
            switch self {
            case .duplicateSerialNumber(let num):
                return "序列号 \(num) 已被使用"
            case .invalidConfiguration(let reason):
                return "配置无效: \(reason)"
            case .creationFailed:
                return "创建虚拟显示器失败"
            case .configNotFound:
                return "找不到显示器配置"
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
    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> CGVirtualDisplay {
        // Check for duplicate serial number in active displays
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
        
        // Create and store config (enabled) only if not already exists
        if !displayConfigs.contains(where: { $0.serialNum == serialNum }) {
            let config = VirtualDisplayConfig(from: display, modes: modes)
            displayConfigs.append(config)
        }
        
        return display
    }
    
    /// Creates a display from a stored configuration
    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        let modes = config.resolutionModes
        return try createDisplay(
            name: config.name,
            serialNum: config.serialNum,
            physicalSize: config.physicalSize,
            maxPixels: config.maxPixelDimensions,
            modes: modes
        )
    }
    
    /// Disables a display (destroys it but keeps the config)
    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        // Find or create config
        if let index = displayConfigs.firstIndex(where: { $0.serialNum == display.serialNum }) {
            displayConfigs[index].isEnabled = false
        } else {
            var config = VirtualDisplayConfig(from: display, modes: modes)
            config.isEnabled = false
            displayConfigs.append(config)
        }
        
        // Remove from active displays (this destroys the display)
        displays.removeAll { $0.serialNum == display.serialNum }
        id = UUID()
    }
    
    /// Disables a display by config ID
    func disableDisplayByConfig(_ configId: UUID) {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else { return }
        
        let serialNum = displayConfigs[index].serialNum
        displayConfigs[index].isEnabled = false
        
        // Remove from active displays
        displays.removeAll { $0.serialNum == serialNum }
        id = UUID()
    }
    
    /// Enables a disabled display
    func enableDisplay(_ configId: UUID) throws {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayError.configNotFound
        }
        
        let config = displayConfigs[index]
        
        // Create the display
        _ = try createDisplayFromConfig(config)
        
        // Update config state
        displayConfigs[index].isEnabled = true
        id = UUID()
    }
    
    /// Completely destroys a display and removes its config
    func destroyDisplay(_ configId: UUID) {
        guard let config = displayConfigs.first(where: { $0.id == configId }) else { return }
        
        // Remove from active displays if enabled
        displays.removeAll { $0.serialNum == config.serialNum }
        
        // Remove config
        displayConfigs.removeAll { $0.id == configId }
        
        id = UUID()
    }
    
    /// Destroys a display by CGVirtualDisplay reference
    func destroyDisplay(_ display: CGVirtualDisplay) {
        let serialNum = display.serialNum
        
        // Remove from active displays
        displays.removeAll { $0.serialNum == serialNum }
        
        // Remove config
        displayConfigs.removeAll { $0.serialNum == serialNum }
        
        id = UUID()
    }
    
    /// Gets the config for a display
    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.serialNum == display.serialNum }
    }
    
    /// Updates the config for a display with new modes
    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        guard let index = displayConfigs.firstIndex(where: { $0.serialNum == display.serialNum }) else { return }
        displayConfigs[index].modes = modes.map {
            VirtualDisplayConfig.ModeConfig(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }
    }
    
    /// Generates the next available serial number
    func nextAvailableSerialNumber() -> UInt32 {
        // Consider both active displays and stored configs
        let activeNumbers = Set(displays.map { $0.serialNum })
        let configNumbers = Set(displayConfigs.map { $0.serialNum })
        let usedNumbers = activeNumbers.union(configNumbers)
        
        var next: UInt32 = 1
        while usedNumbers.contains(next) {
            next += 1
        }
        return next
    }
}


