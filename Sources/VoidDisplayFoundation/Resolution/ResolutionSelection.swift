//
//  ResolutionSelection.swift
//  VoidDisplay
//
//  Data model for user-selected resolution modes
//

import Foundation

/// Represents a single display resolution mode that can be preset or custom
package struct ResolutionSelection: Identifiable, Hashable {
    package let id = UUID()
    package var width: Int
    package var height: Int
    package var refreshRate: Double
    package var enableHiDPI: Bool  // Per-resolution HiDPI setting
    
    /// Initialize from a preset resolution
    /// - Parameters:
    ///   - preset: A preset resolution from the DisplayResolutionPreset enum
    ///   - refreshRate: Refresh rate in Hz (default: 60.0)
    ///   - enableHiDPI: Whether to enable HiDPI for this resolution (default: true)
    package init(preset: DisplayResolutionPreset, refreshRate: Double = 60.0, enableHiDPI: Bool = true) {
        let (w, h) = preset.logicalSize
        self.width = w
        self.height = h
        self.refreshRate = refreshRate
        self.enableHiDPI = enableHiDPI
    }
    
    /// Initialize with custom resolution values
    /// - Parameters:
    ///   - width: Width in pixels
    ///   - height: Height in pixels
    ///   - refreshRate: Refresh rate in Hz (default: 60.0)
    ///   - enableHiDPI: Whether to enable HiDPI for this resolution (default: true)
    package init(width: Int, height: Int, refreshRate: Double = 60.0, enableHiDPI: Bool = true) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.enableHiDPI = enableHiDPI
    }
    
    /// Display string for UI
    package var displayString: String {
        let hiDPIIndicator = enableHiDPI ? " [HiDPI]" : ""
        return "\(width) × \(height) @ \(Int(refreshRate))Hz\(hiDPIIndicator)"
    }
    
    /// Generate HiDPI (2x) version of this resolution
    package func hiDPIVersion() -> ResolutionSelection {
        ResolutionSelection(
            width: width * 2,
            height: height * 2,
            refreshRate: refreshRate,
            enableHiDPI: false  // The 2x version itself doesn't need HiDPI flag
        )
    }
    
    // MARK: - Hashable conformance
    package func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(refreshRate)
        hasher.combine(enableHiDPI)
    }
    
    package static func == (lhs: ResolutionSelection, rhs: ResolutionSelection) -> Bool {
        lhs.id == rhs.id &&
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.refreshRate == rhs.refreshRate &&
        lhs.enableHiDPI == rhs.enableHiDPI
    }

    /// Duplicate check helper that ignores `id` and `enableHiDPI`.
    package func matchesResolution(of other: ResolutionSelection) -> Bool {
        width == other.width &&
        height == other.height &&
        refreshRate == other.refreshRate
    }
}
