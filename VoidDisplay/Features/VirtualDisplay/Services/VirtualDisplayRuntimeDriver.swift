import CoreGraphics
import Foundation

@MainActor
protocol VirtualDisplayRuntimeHandling: AnyObject {
    var serialNum: UInt32 { get }
    var displayID: CGDirectDisplayID { get }
    func applyModes(_ modes: [ResolutionSelection]) -> Bool
}

@MainActor
protocol VirtualDisplayRuntimeDriving: AnyObject {
    func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)?,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling
}
