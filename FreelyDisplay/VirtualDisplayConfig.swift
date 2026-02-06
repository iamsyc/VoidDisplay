//
//  VirtualDisplayConfig.swift
//  FreelyDisplay
//
//  Configuration model for virtual displays (used for enable/disable functionality)
//

import Foundation
import CoreGraphics

/// Stores the configuration of a virtual display for later restoration
struct VirtualDisplayConfig: Identifiable, Codable {
    let id: UUID
    var name: String
    var serialNum: UInt32
    var physicalWidth: Int  // in millimeters
    var physicalHeight: Int // in millimeters
    var modes: [ModeConfig]
    /// Persisted user intent: whether this config should be enabled (auto-restored) by default.
    var desiredEnabled: Bool
    
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
        desiredEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.serialNum = serialNum
        self.physicalWidth = physicalWidth
        self.physicalHeight = physicalHeight
        self.modes = modes
        self.desiredEnabled = desiredEnabled
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
        self.desiredEnabled = true
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case serialNum
        case physicalWidth
        case physicalHeight
        case modes
        case desiredEnabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        serialNum = try container.decode(UInt32.self, forKey: .serialNum)
        physicalWidth = try container.decode(Int.self, forKey: .physicalWidth)
        physicalHeight = try container.decode(Int.self, forKey: .physicalHeight)
        modes = try container.decode([ModeConfig].self, forKey: .modes)

        desiredEnabled = try container.decode(Bool.self, forKey: .desiredEnabled)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(serialNum, forKey: .serialNum)
        try container.encode(physicalWidth, forKey: .physicalWidth)
        try container.encode(physicalHeight, forKey: .physicalHeight)
        try container.encode(modes, forKey: .modes)
        try container.encode(desiredEnabled, forKey: .desiredEnabled)
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
