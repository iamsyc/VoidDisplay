import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation

package struct VirtualDisplayRuntimePixelDimensions: Equatable, Sendable {
    package let width: UInt32
    package let height: UInt32

    package init(width: UInt32, height: UInt32) {
        self.width = width
        self.height = height
    }
}

package struct VirtualDisplayRuntimeMode: Equatable, Sendable {
    package let width: Int
    package let height: Int
    package let refreshRate: Double
    package let isHiDPI: Bool

    package init(width: Int, height: Int, refreshRate: Double, isHiDPI: Bool) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
    }
}

package struct VirtualDisplayRuntimeDescriptor: Equatable, Sendable {
    package let name: String
    package let serialNumber: UInt32
    package let physicalSize: CGSize
    package let maximumPixelDimensions: VirtualDisplayRuntimePixelDimensions
    package let modes: [VirtualDisplayRuntimeMode]

    package init(
        name: String,
        serialNumber: UInt32,
        physicalSize: CGSize,
        maximumPixelDimensions: VirtualDisplayRuntimePixelDimensions,
        modes: [VirtualDisplayRuntimeMode]
    ) {
        self.name = name
        self.serialNumber = serialNumber
        self.physicalSize = physicalSize
        self.maximumPixelDimensions = maximumPixelDimensions
        self.modes = modes
    }
}

@MainActor
package protocol VirtualDisplayRuntimeHandling: AnyObject {
    var serialNum: UInt32 { get }
    var displayID: CGDirectDisplayID { get }
    func applyModes(_ modes: [VirtualDisplayRuntimeMode]) -> Bool
}

@MainActor
package protocol VirtualDisplayRuntimeDriving: AnyObject {
    func createRuntimeDisplay(
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling
}
