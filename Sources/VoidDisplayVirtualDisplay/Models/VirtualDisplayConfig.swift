import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
//
//  VirtualDisplayConfig.swift
//  VoidDisplay
//
//  Configuration model for virtual displays (used for enable/disable functionality)
//

import CryptoKit
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
        precondition(!modes.isEmpty, "VirtualDisplayConfig requires at least one mode.")
        precondition(
            modes.allSatisfy { $0.width > 0 && $0.height > 0 && $0.refreshRate.isFinite && $0.refreshRate > 0 },
            "VirtualDisplayConfig contains invalid modes."
        )
        let maxMode = modes.max(by: { pixelArea($0) < pixelArea($1) })!
        let anyHiDPI = modes.contains { $0.enableHiDPI }
        let scale: UInt64 = anyHiDPI ? 2 : 1
        let (scaledWidth, widthOverflow) = UInt64(maxMode.width).multipliedReportingOverflow(by: scale)
        let (scaledHeight, heightOverflow) = UInt64(maxMode.height).multipliedReportingOverflow(by: scale)
        precondition(!widthOverflow && !heightOverflow, "VirtualDisplayConfig max pixel dimensions overflowed.")
        guard let width = UInt32(exactly: scaledWidth),
              let height = UInt32(exactly: scaledHeight) else {
            preconditionFailure("VirtualDisplayConfig max pixel dimensions exceed UInt32.")
        }
        return (width, height)
    }

    package var editRebuildFingerprint: String {
        let maxPixels = maxPixelDimensions
        let canonical = [
            "v1",
            "id=\(id.uuidString.lowercased())",
            "displayName=\(lengthPrefixed(displayName))",
            "serialNumber=\(serialNum)",
            "desiredEnabled=\(desiredEnabled ? 1 : 0)",
            "physicalWidthMillimeters=\(UInt32(clamping: physicalWidth))",
            "physicalHeightMillimeters=\(UInt32(clamping: physicalHeight))",
            "maximumPixelWidth=\(maxPixels.width)",
            "maximumPixelHeight=\(maxPixels.height)",
            "modes=\(modes.map(Self.modeFingerprintComponent).joined(separator: ";"))"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func pixelArea(_ mode: ModeConfig) -> UInt64 {
        let (area, overflow) = UInt64(mode.width).multipliedReportingOverflow(by: UInt64(mode.height))
        precondition(!overflow, "VirtualDisplayConfig mode pixel area overflowed.")
        return area
    }

    private func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func modeFingerprintComponent(_ mode: ModeConfig) -> String {
        [
            "\(mode.width)",
            "\(mode.height)",
            "\(mode.refreshRate.bitPattern)",
            mode.enableHiDPI ? "1" : "0"
        ].joined(separator: ",")
    }
    
    /// Physical size as CGSize
    package var physicalSize: CGSize {
        CGSize(width: physicalWidth, height: physicalHeight)
    }
}
