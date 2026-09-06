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

    /// Get resolution selections from stored modes
    package var resolutionModes: [ResolutionSelection] {
        modes.map { $0.toResolutionSelection() }
    }
    
    /// Get max pixel dimensions
    package var maxPixelDimensions: (width: UInt32, height: UInt32) {
        do {
            return try VirtualDisplayModeBounds.resolve(resolutionModes)
        } catch {
            preconditionFailure("VirtualDisplayConfig contains invalid modes: \(error.rawValue)")
        }
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
