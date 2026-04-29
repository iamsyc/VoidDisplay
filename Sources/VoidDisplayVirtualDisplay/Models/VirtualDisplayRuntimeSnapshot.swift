import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
package struct VirtualDisplayRuntimeSnapshot {
    package var runtimeName: String
    package var serialNum: UInt32
    package var displayID: CGDirectDisplayID
    package var modes: [ResolutionSelection]
}
