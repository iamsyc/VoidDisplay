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
import CoreGraphics

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
    @Published var displayConfigs:[VirtualDisplayConfig]=[]  // Stored configs (persisted)
    static var shared=AppHelper()
    @Published var id=UUID()
    @Published var screenCaptureObjects:[SCStream?]=[]
    @Published var sharingScreenCaptureObject:SCStream?=nil
    @Published var sharingScreenCaptureStream:Capture?=nil
    @Published var isSharing=false
    let webServer=try? WebServer(using: 8081)

    private let virtualDisplayStore = VirtualDisplayStore()
    private var activeDisplaysByConfigId: [UUID: CGVirtualDisplay] = [:]

    init() {
        webServer?.startListener()

        do {
            displayConfigs = try virtualDisplayStore.load()
        } catch {
            NSLog("Failed to load virtual display configs: \(error.localizedDescription)")
            displayConfigs = []
        }

        DispatchQueue.main.async { [weak self] in
            self?.restoreDesiredVirtualDisplays()
        }
    }

    private func persistVirtualDisplayConfigs() {
        do {
            try virtualDisplayStore.save(displayConfigs)
        } catch {
            NSLog("Failed to save virtual display configs: \(error.localizedDescription)")
        }
    }

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay? {
        activeDisplaysByConfigId[configId]
    }

    func isVirtualDisplayRunning(configId: UUID) -> Bool {
        activeDisplaysByConfigId[configId] != nil
    }

    private func restoreDesiredVirtualDisplays() {
        for config in displayConfigs where config.desiredEnabled {
            do {
                _ = try createRuntimeDisplay(from: config)
            } catch {
                NSLog("Failed to restore virtual display \(config.serialNum): \(error.localizedDescription)")
            }
        }
        id = UUID()
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
                return String(localized: "Serial number \(num) is already in use.")
            case .invalidConfiguration(let reason):
                return String(localized: "Invalid configuration: \(reason)")
            case .creationFailed:
                return String(localized: "Virtual display creation failed.")
            case .configNotFound:
                return String(localized: "Display configuration not found.")
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
        if displays.contains(where: { $0.serialNum == serialNum }) ||
            displayConfigs.contains(where: { $0.serialNum == serialNum }) {
            throw VirtualDisplayError.duplicateSerialNumber(serialNum)
        }
        
        // Validate modes
        guard !modes.isEmpty else {
            throw VirtualDisplayError.invalidConfiguration(String(localized: "At least one resolution mode is required."))
        }

        let config = VirtualDisplayConfig(
            name: name,
            serialNum: serialNum,
            physicalWidth: Int(physicalSize.width),
            physicalHeight: Int(physicalSize.height),
            modes: modes.map {
                VirtualDisplayConfig.ModeConfig(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            },
            desiredEnabled: true
        )

        displayConfigs.append(config)
        persistVirtualDisplayConfigs()

        do {
            let display = try createRuntimeDisplay(from: config, maxPixels: maxPixels)
            id = UUID()
            return display
        } catch {
            displayConfigs.removeAll { $0.id == config.id }
            persistVirtualDisplayConfigs()
            throw error
        }
    }

    private func createRuntimeDisplay(from config: VirtualDisplayConfig, maxPixels: (width: UInt32, height: UInt32)? = nil) throws -> CGVirtualDisplay {
        // Already running
        if let existing = activeDisplaysByConfigId[config.id] {
            return existing
        }

        // Prevent duplicate serial numbers among runtime displays
        if displays.contains(where: { $0.serialNum == config.serialNum }) {
            throw VirtualDisplayError.duplicateSerialNumber(config.serialNum)
        }

        // Validate modes
        let modes = config.resolutionModes
        guard !modes.isEmpty else {
            throw VirtualDisplayError.invalidConfiguration(String(localized: "At least one resolution mode is required."))
        }

        // Configure descriptor
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleVirtualDisplayTermination(configId: config.id, serialNum: config.serialNum)
            }
        }
        desc.name = config.name
        let max = maxPixels ?? config.maxPixelDimensions
        desc.maxPixelsWide = max.width
        desc.maxPixelsHigh = max.height
        desc.sizeInMillimeters = config.physicalSize
        desc.productID = 0x1234
        desc.vendorID = 0x3456
        desc.serialNum = config.serialNum

        // Create display
        let display = CGVirtualDisplay(descriptor: desc)

        // Configure settings
        let settings = CGVirtualDisplaySettings()
        let anyHiDPI = modes.contains { $0.enableHiDPI }
        settings.hiDPI = anyHiDPI ? 1 : 0

        var displayModes: [CGVirtualDisplayMode] = []
        for mode in modes {
            if mode.enableHiDPI {
                displayModes.append(mode.hiDPIVersion().toVirtualDisplayMode())
            }
            displayModes.append(mode.toVirtualDisplayMode())
        }

        settings.modes = displayModes
        display.apply(settings)

        // Track runtime display
        activeDisplaysByConfigId[config.id] = display
        displays.removeAll { $0.serialNum == config.serialNum }
        displays.append(display)
        return display
    }

    private func handleVirtualDisplayTermination(configId: UUID, serialNum: UInt32) {
        activeDisplaysByConfigId[configId] = nil
        displays.removeAll { $0.serialNum == serialNum }
        id = UUID()
    }
    
    /// Creates a display from a stored configuration
    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        try createRuntimeDisplay(from: config)
    }
    
    /// Disables a display (destroys it but keeps the config)
    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        // Find or create config
        if let index = displayConfigs.firstIndex(where: { $0.serialNum == display.serialNum }) {
            displayConfigs[index].desiredEnabled = false
        } else {
            var config = VirtualDisplayConfig(from: display, modes: modes)
            config.desiredEnabled = false
            displayConfigs.append(config)
        }
        
        // Remove from active displays (this destroys the display)
        displays.removeAll { $0.serialNum == display.serialNum }
        for (configId, activeDisplay) in activeDisplaysByConfigId where activeDisplay.serialNum == display.serialNum {
            activeDisplaysByConfigId[configId] = nil
        }
        persistVirtualDisplayConfigs()
        id = UUID()
    }
    
    /// Disables a display by config ID
    func disableDisplayByConfig(_ configId: UUID) {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else { return }
        
        displayConfigs[index].desiredEnabled = false
        
        // Remove from active displays
        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? displayConfigs[index].serialNum
        activeDisplaysByConfigId[configId] = nil
        displays.removeAll { $0.serialNum == runtimeSerialNum }
        persistVirtualDisplayConfigs()
        id = UUID()
    }
    
    /// Enables a disabled display
    func enableDisplay(_ configId: UUID) throws {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayError.configNotFound
        }

        // Persist user intent first (even if runtime creation fails)
        displayConfigs[index].desiredEnabled = true
        persistVirtualDisplayConfigs()

        let config = displayConfigs[index]
        _ = try createRuntimeDisplay(from: config)
        id = UUID()
    }
    
    /// Completely destroys a display and removes its config
    func destroyDisplay(_ configId: UUID) {
        guard let config = displayConfigs.first(where: { $0.id == configId }) else { return }
        
        // Remove from active displays if enabled
        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? config.serialNum
        activeDisplaysByConfigId[configId] = nil
        displays.removeAll { $0.serialNum == runtimeSerialNum }
        
        // Remove config
        displayConfigs.removeAll { $0.id == configId }
        persistVirtualDisplayConfigs()
        
        id = UUID()
    }
    
    /// Destroys a display by CGVirtualDisplay reference
    func destroyDisplay(_ display: CGVirtualDisplay) {
        let serialNum = display.serialNum
        
        // Remove from active displays
        displays.removeAll { $0.serialNum == serialNum }
        for (configId, activeDisplay) in activeDisplaysByConfigId where activeDisplay.serialNum == serialNum {
            activeDisplaysByConfigId[configId] = nil
        }
        
        // Remove config
        displayConfigs.removeAll { $0.serialNum == serialNum }
        persistVirtualDisplayConfigs()
        
        id = UUID()
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.id == configId }
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        guard let index = displayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        displayConfigs[index] = updated
        persistVirtualDisplayConfigs()
        id = UUID()
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        guard let display = activeDisplaysByConfigId[configId] else { return }
        let settings = CGVirtualDisplaySettings()

        let anyHiDPI = modes.contains { $0.enableHiDPI }
        settings.hiDPI = anyHiDPI ? 1 : 0

        var displayModes: [CGVirtualDisplayMode] = []
        for mode in modes {
            if mode.enableHiDPI {
                displayModes.append(mode.hiDPIVersion().toVirtualDisplayMode())
            }
            displayModes.append(mode.toVirtualDisplayMode())
        }
        settings.modes = displayModes
        display.apply(settings)
    }

    func rebuildVirtualDisplay(configId: UUID) throws {
        guard let config = displayConfigs.first(where: { $0.id == configId }) else {
            throw VirtualDisplayError.configNotFound
        }

        if let running = activeDisplaysByConfigId[configId] {
            activeDisplaysByConfigId[configId] = nil
            displays.removeAll { $0.serialNum == running.serialNum }
        }

        _ = try createRuntimeDisplay(from: config)
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
        persistVirtualDisplayConfigs()
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
