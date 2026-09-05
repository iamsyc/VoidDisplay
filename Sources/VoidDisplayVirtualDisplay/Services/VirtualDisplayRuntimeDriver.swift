import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation

package struct VirtualDisplayRuntimePixelDimensions: Equatable, Codable, Sendable {
    package let width: UInt32
    package let height: UInt32

    package init(width: UInt32, height: UInt32) {
        self.width = width
        self.height = height
    }
}

package struct VirtualDisplayRuntimeMode: Equatable, Codable, Sendable {
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

package struct VirtualDisplayRuntimeDescriptor: Equatable, Codable, Sendable {
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
package protocol VirtualDisplayRuntimeHandling: AnyObject, Sendable {
    var serialNum: UInt32 { get }
    var displayID: CGDirectDisplayID { get }
}

@MainActor
package protocol VirtualDisplayRuntimeDriving: AnyObject {
    func createRuntimeDisplay(
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) async throws -> any VirtualDisplayRuntimeHandling
}

/// The host reports readiness only after selecting and reading back the actual mode.
package enum VirtualDisplayHostResponse: Codable, Sendable {
    case ready(displayID: CGDirectDisplayID, mode: VirtualDisplayRuntimeDisplayMode)
    case failed(String)
}

package struct VirtualDisplayRuntimeDisplayMode: Equatable, Codable, Sendable {
    package let id: Int32
    package let width: Int
    package let height: Int
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let refreshRate: Double

    package init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }
}
