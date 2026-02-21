//
//  DisplayConfig.swift
//  VoidDisplay
//
//  Flexible display configuration with composable options
//

import Foundation

/// Common aspect ratios for displays
enum AspectRatio: String, CaseIterable, Identifiable {
    case ratio_16_9  = "16:9"   // Most Windows monitors, TVs
    case ratio_16_10 = "16:10"  // MacBook, some professional monitors
    case ratio_4_3   = "4:3"    // Legacy displays
    case ratio_21_9  = "21:9"   // Ultrawide monitors
    case ratio_32_9  = "32:9"   // Super ultrawide
    
    var id: String { rawValue }
    
    /// Width and height ratio components
    var components: (width: Double, height: Double) {
        switch self {
        case .ratio_16_9:  return (16, 9)
        case .ratio_16_10: return (16, 10)
        case .ratio_4_3:   return (4, 3)
        case .ratio_21_9:  return (21, 9)
        case .ratio_32_9:  return (32, 9)
        }
    }
    
    /// Calculate physical dimensions in millimeters from diagonal inches
    /// Formula: 
    ///   diagonal_mm = inches * 25.4
    ///   width_mm = diagonal_mm * cos(atan(height_ratio / width_ratio))
    ///   height_mm = diagonal_mm * sin(atan(height_ratio / width_ratio))
    func sizeInMillimeters(diagonalInches: Double) -> (width: Int, height: Int) {
        let (w, h) = components
        let diagonalMM = diagonalInches * 25.4
        let angle = atan(h / w)
        let widthMM = diagonalMM * cos(angle)
        let heightMM = diagonalMM * sin(angle)
        return (Int(round(widthMM)), Int(round(heightMM)))
    }
}

/// Helper to calculate display parameters
struct DisplayCalculator {
    
    /// Calculate physical pixels based on logical resolution and HiDPI setting
    static func physicalPixels(logicalWidth: Int, logicalHeight: Int, hiDPI: Bool) -> (width: Int, height: Int) {
        let multiplier = hiDPI ? 2 : 1
        return (logicalWidth * multiplier, logicalHeight * multiplier)
    }
    
    /// Calculate PPI (Pixels Per Inch) for given resolution and physical size
    static func calculatePPI(widthPixels: Int, heightPixels: Int, diagonalInches: Double) -> Double {
        let diagonalPixels = sqrt(Double(widthPixels * widthPixels + heightPixels * heightPixels))
        return diagonalPixels / diagonalInches
    }
}
