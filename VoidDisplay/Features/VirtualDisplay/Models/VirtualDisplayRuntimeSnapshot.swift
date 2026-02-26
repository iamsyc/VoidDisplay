import CoreGraphics
import Foundation

struct VirtualDisplayRuntimeSnapshot {
    var runtimeName: String
    var serialNum: UInt32
    var displayID: CGDirectDisplayID
    var modes: [ResolutionSelection]
}
