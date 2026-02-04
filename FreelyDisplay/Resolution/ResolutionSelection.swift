//
//  ResolutionSelection.swift
//  FreelyDisplay
//
//  Data model for user-selected resolution modes
//

import Foundation

/// Represents a single display resolution mode that can be preset or custom
struct ResolutionSelection: Identifiable, Hashable {
    let id = UUID()
    var width: Int
    var height: Int
    var refreshRate: Double
    
    /// Initialize from a preset resolution
    /// - Parameters:
    ///   - preset: A preset resolution from the Resolutions enum
    ///   - refreshRate: Refresh rate in Hz (default: 60.0)
    init(preset: Resolutions, refreshRate: Double = 60.0) {
        let (w, h) = preset.resolutions
        self.width = w
        self.height = h
        self.refreshRate = refreshRate
    }
    
    /// Initialize with custom resolution values
    /// - Parameters:
    ///   - width: Width in pixels
    ///   - height: Height in pixels
    ///   - refreshRate: Refresh rate in Hz (default: 60.0)
    init(width: Int, height: Int, refreshRate: Double = 60.0) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }
    
    /// Display string for UI
    var displayString: String {
        "\(width) × \(height) @ \(Int(refreshRate))Hz"
    }
    
    /// Convert to CGVirtualDisplayMode
    func toVirtualDisplayMode() -> CGVirtualDisplayMode {
        CGVirtualDisplayMode(
            width: UInt(width),
            height: UInt(height),
            refreshRate: CGFloat(refreshRate)
        )
    }
    
    /// Generate HiDPI (2x) version of this resolution
    func hiDPIVersion() -> ResolutionSelection {
        ResolutionSelection(
            width: width * 2,
            height: height * 2,
            refreshRate: refreshRate
        )
    }
    
    // MARK: - Hashable conformance (exclude id for value-based comparison)
    func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(refreshRate)
    }
    
    static func == (lhs: ResolutionSelection, rhs: ResolutionSelection) -> Bool {
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.refreshRate == rhs.refreshRate
    }
}
