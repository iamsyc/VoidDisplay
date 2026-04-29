import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
//
//  VirtualDisplayConfig.swift
//  VoidDisplay
//
//  Configuration model for virtual displays (used for enable/disable functionality)
//

import Foundation
import CoreGraphics

/// Stores the configuration of a virtual display for later restoration
package struct VirtualDisplayConfig: Identifiable, Codable, Equatable {
    package let id: UUID
    package var displayName: String
    package var serialNum: UInt32
    package var physicalWidth: Int  // in millimeters
    package var physicalHeight: Int // in millimeters
    package var modes: [ModeConfig]
    /// Persisted user intent: whether this config should be enabled (auto-restored) by default.
    package var desiredEnabled: Bool
    
    /// Mode configuration
    package struct ModeConfig: Codable, Hashable {
        package var width: Int
        package var height: Int
        package var refreshRate: Double
        package var enableHiDPI: Bool

        package init(width: Int, height: Int, refreshRate: Double, enableHiDPI: Bool) {
            self.width = width
            self.height = height
            self.refreshRate = refreshRate
            self.enableHiDPI = enableHiDPI
        }
        
        func toResolutionSelection() -> ResolutionSelection {
            ResolutionSelection(
                width: width,
                height: height,
                refreshRate: refreshRate,
                enableHiDPI: enableHiDPI
            )
        }
    }
    
    package init(
        id: UUID = UUID(),
        displayName: String,
        serialNum: UInt32,
        physicalWidth: Int,
        physicalHeight: Int,
        modes: [ModeConfig],
        desiredEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.serialNum = serialNum
        self.physicalWidth = physicalWidth
        self.physicalHeight = physicalHeight
        self.modes = modes
        self.desiredEnabled = desiredEnabled
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case serialNum
        case physicalWidth
        case physicalHeight
        case modes
        case desiredEnabled
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        serialNum = try container.decode(UInt32.self, forKey: .serialNum)
        physicalWidth = try container.decode(Int.self, forKey: .physicalWidth)
        physicalHeight = try container.decode(Int.self, forKey: .physicalHeight)
        modes = try container.decode([ModeConfig].self, forKey: .modes)

        desiredEnabled = try container.decode(Bool.self, forKey: .desiredEnabled)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(serialNum, forKey: .serialNum)
        try container.encode(physicalWidth, forKey: .physicalWidth)
        try container.encode(physicalHeight, forKey: .physicalHeight)
        try container.encode(modes, forKey: .modes)
        try container.encode(desiredEnabled, forKey: .desiredEnabled)
    }
    
    /// Get resolution selections from stored modes
    package var resolutionModes: [ResolutionSelection] {
        modes.map { $0.toResolutionSelection() }
    }
    
    /// Get max pixel dimensions
    package var maxPixelDimensions: (width: UInt32, height: UInt32) {
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
    package var physicalSize: CGSize {
        CGSize(width: physicalWidth, height: physicalHeight)
    }
}
