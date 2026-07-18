import VoidDisplayVirtualDisplay
import VoidDisplayFoundation
import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

@MainActor
package final class CGVirtualDisplayRuntimeDriver: VirtualDisplayRuntimeDriving {
    package func createRuntimeDisplay(
        descriptor runtimeDescriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling {
        let cgDescriptor = CGVirtualDisplayDescriptor()
        cgDescriptor.setDispatchQueue(DispatchQueue.main)
        cgDescriptor.terminationHandler = { _, _ in
            Task { @MainActor in
                onTermination()
            }
        }
        cgDescriptor.name = runtimeDescriptor.name
        cgDescriptor.maxPixelsWide = runtimeDescriptor.maximumPixelDimensions.width
        cgDescriptor.maxPixelsHigh = runtimeDescriptor.maximumPixelDimensions.height
        cgDescriptor.sizeInMillimeters = runtimeDescriptor.physicalSize
        cgDescriptor.productID = ManagedVirtualDisplayIdentity.productID
        cgDescriptor.vendorID = ManagedVirtualDisplayIdentity.vendorID
        cgDescriptor.serialNum = runtimeDescriptor.serialNumber

        let display = CGVirtualDisplay(descriptor: cgDescriptor)
        let runtimeHandle = CGVirtualDisplayRuntimeHandle(display: display)
        let applied = runtimeHandle.applyModes(runtimeDescriptor.modes)
        guard applied else {
            throw VirtualDisplayOperationError.creationFailed
        }
        return runtimeHandle
    }
}

@MainActor
package func makeVirtualDisplayRuntimeDriver() -> any VirtualDisplayRuntimeDriving {
    CGVirtualDisplayRuntimeDriver()
}

@MainActor
private final class CGVirtualDisplayRuntimeHandle: VirtualDisplayRuntimeHandling {
    private let display: CGVirtualDisplay

    package init(display: CGVirtualDisplay) {
        self.display = display
    }

    package var serialNum: UInt32 {
        display.serialNum
    }

    package var displayID: CGDirectDisplayID {
        display.displayID
    }

    package func applyModes(_ modes: [VirtualDisplayRuntimeMode]) -> Bool {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = modes.contains(where: { $0.isHiDPI }) ? 1 : 0
        settings.modes = buildDisplayModes(from: modes)
        return display.apply(settings)
    }

    private func buildDisplayModes(from modes: [VirtualDisplayRuntimeMode]) -> [CGVirtualDisplayMode] {
        var displayModes: [CGVirtualDisplayMode] = []
        for mode in modes {
            if mode.isHiDPI {
                displayModes.append(
                    CGVirtualDisplayMode(
                        width: UInt(mode.width * 2),
                        height: UInt(mode.height * 2),
                        refreshRate: CGFloat(mode.refreshRate)
                    )
                )
            }
            displayModes.append(
                CGVirtualDisplayMode(
                    width: UInt(mode.width),
                    height: UInt(mode.height),
                    refreshRate: CGFloat(mode.refreshRate)
                )
            )
        }
        return displayModes
    }
}
