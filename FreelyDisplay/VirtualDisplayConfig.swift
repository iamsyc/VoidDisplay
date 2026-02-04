//
//  VirtualDisplayConfig.swift
//  FreelyDisplay
//
//  Configuration model for virtual displays (used for enable/disable functionality)
//

import Foundation

/// Stores the configuration of a virtual display for later restoration
struct VirtualDisplayConfig: Identifiable, Codable {
    let id: UUID
    var name: String
    var serialNum: UInt32
    var physicalWidth: Int  // in millimeters
    var physicalHeight: Int // in millimeters
    var modes: [ModeConfig]
    var isEnabled: Bool
    
    /// Mode configuration
    struct ModeConfig: Codable, Hashable {
        var width: Int
        var height: Int
        var refreshRate: Double
        var enableHiDPI: Bool
        
        func toResolutionSelection() -> ResolutionSelection {
            ResolutionSelection(
                width: width,
                height: height,
                refreshRate: refreshRate,
                enableHiDPI: enableHiDPI
            )
        }
    }
    
    init(
        id: UUID = UUID(),
        name: String,
        serialNum: UInt32,
        physicalWidth: Int,
        physicalHeight: Int,
        modes: [ModeConfig],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.serialNum = serialNum
        self.physicalWidth = physicalWidth
        self.physicalHeight = physicalHeight
        self.modes = modes
        self.isEnabled = isEnabled
    }
    
    /// Create from a CGVirtualDisplay and its modes
    init(from display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        self.id = UUID()
        self.name = display.name
        self.serialNum = display.serialNum
        self.physicalWidth = Int(display.sizeInMillimeters.width)
        self.physicalHeight = Int(display.sizeInMillimeters.height)
        self.modes = modes.map { ModeConfig(
            width: $0.width,
            height: $0.height,
            refreshRate: $0.refreshRate,
            enableHiDPI: $0.enableHiDPI
        )}
        self.isEnabled = true
    }
    
    /// Get resolution selections from stored modes
    var resolutionModes: [ResolutionSelection] {
        modes.map { $0.toResolutionSelection() }
    }
    
    /// Get max pixel dimensions
    var maxPixelDimensions: (width: UInt32, height: UInt32) {
        guard let maxMode = modes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
            return (1920, 1080)
        }
        let anyHiDPI = modes.contains { $0.enableHiDPI }
        if anyHiDPI {
            return (UInt32(maxMode.width * 2), UInt32(maxMode.height * 2))
        }
        return (UInt32(maxMode.width), UInt32(maxMode.height))
    }
    
    /// Physical size as CGSize
    var physicalSize: CGSize {
        CGSize(width: physicalWidth, height: physicalHeight)
    }
}
