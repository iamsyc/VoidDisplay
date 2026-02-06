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
    var enableHiDPI: Bool  // Per-resolution HiDPI setting
    
    /// Initialize from a preset resolution
    /// - Parameters:
    ///   - preset: A preset resolution from the Resolutions enum
    ///   - refreshRate: Refresh rate in Hz (default: 60.0)
    ///   - enableHiDPI: Whether to enable HiDPI for this resolution (default: true)
    init(preset: Resolutions, refreshRate: Double = 60.0, enableHiDPI: Bool = true) {
        let (w, h) = preset.resolutions
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
    init(width: Int, height: Int, refreshRate: Double = 60.0, enableHiDPI: Bool = true) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.enableHiDPI = enableHiDPI
    }
    
    /// Display string for UI
    var displayString: String {
        let hiDPIIndicator = enableHiDPI ? " [HiDPI]" : ""
        return "\(width) × \(height) @ \(Int(refreshRate))Hz\(hiDPIIndicator)"
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
            refreshRate: refreshRate,
            enableHiDPI: false  // The 2x version itself doesn't need HiDPI flag
        )
    }
    
    // MARK: - Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(refreshRate)
        hasher.combine(enableHiDPI)
    }
    
    static func == (lhs: ResolutionSelection, rhs: ResolutionSelection) -> Bool {
        lhs.id == rhs.id &&
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.refreshRate == rhs.refreshRate &&
        lhs.enableHiDPI == rhs.enableHiDPI
    }

    /// Duplicate check helper that ignores `id` and `enableHiDPI`.
    func matchesResolution(of other: ResolutionSelection) -> Bool {
        width == other.width &&
        height == other.height &&
        refreshRate == other.refreshRate
    }
}
