import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation

@MainActor
package protocol VirtualDisplayRuntimeHandling: AnyObject {
    var serialNum: UInt32 { get }
    var displayID: CGDirectDisplayID { get }
    func applyModes(_ modes: [ResolutionSelection]) -> Bool
}

@MainActor
package protocol VirtualDisplayRuntimeDriving: AnyObject {
    func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)?,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling
}
