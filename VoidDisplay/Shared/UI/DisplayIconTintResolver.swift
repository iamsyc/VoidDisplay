import SwiftUI

/// Computes the icon screen tint color based on the display's functional state.
///
/// The tint is applied to the secondary (screen face) layer of SF Symbols
/// rendered in `.palette` mode. Returns `nil` when the display has no
/// active function, meaning the icon should use the default monochrome style.
enum DisplayIconTintResolver {
    /// Screen tint for a display that is enabled but has no monitoring/sharing.
    static let enabledIdle = Color.blue.opacity(0.45)

    /// Screen tint for a display actively being monitored (cool spring green).
    /// RGB ≈ (0.25, 0.80, 0.55)
    static let monitoring = Color(red: 0.25, green: 0.80, blue: 0.55).opacity(0.55)

    /// Screen tint for a display actively being shared (warm amber orange).
    /// RGB ≈ (1.00, 0.65, 0.10)
    static let sharing = Color(red: 1.00, green: 0.65, blue: 0.10).opacity(0.55)

    /// Weighted blend of monitoring + sharing (35% green + 65% orange) → warm golden amber.
    /// Biased toward sharing/warning. RGB = (0.25×0.35+1.00×0.65, 0.80×0.35+0.65×0.65, 0.55×0.35+0.10×0.65)
    static let monitoringAndSharing = Color(red: 0.7375, green: 0.7025, blue: 0.2575).opacity(0.55)

    /// Returns the appropriate screen tint for the given functional state.
    ///
    /// - Parameters:
    ///   - isMonitoring: Whether the display is currently being monitored.
    ///   - isSharing: Whether the display is currently being shared.
    /// - Returns: The tint color, or `nil` if neither monitoring nor sharing.
    static func resolve(isMonitoring: Bool, isSharing: Bool) -> Color? {
        switch (isMonitoring, isSharing) {
        case (true, true):   return monitoringAndSharing
        case (true, false):  return monitoring
        case (false, true):  return sharing
        case (false, false): return nil
        }
    }
}
