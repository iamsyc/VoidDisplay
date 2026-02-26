import CoreGraphics
import Foundation

@MainActor
final class CGVirtualDisplayRuntimeDriver: VirtualDisplayRuntimeDriving {
    func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)?,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.terminationHandler = { _, _ in
            Task { @MainActor in
                onTermination()
            }
        }
        descriptor.name = config.displayName
        let resolvedMaxPixels = maxPixels ?? config.maxPixelDimensions
        descriptor.maxPixelsWide = resolvedMaxPixels.width
        descriptor.maxPixelsHigh = resolvedMaxPixels.height
        descriptor.sizeInMillimeters = config.physicalSize
        descriptor.productID = ManagedVirtualDisplayIdentity.productID
        descriptor.vendorID = ManagedVirtualDisplayIdentity.vendorID
        descriptor.serialNum = config.serialNum

        let display = CGVirtualDisplay(descriptor: descriptor)
        let runtimeHandle = CGVirtualDisplayRuntimeHandle(display: display)
        let applied = runtimeHandle.applyModes(config.resolutionModes)
        guard applied else {
            throw VirtualDisplayOperationError.creationFailed
        }
        return runtimeHandle
    }
}

@MainActor
func makeVirtualDisplayRuntimeDriver() -> any VirtualDisplayRuntimeDriving {
    CGVirtualDisplayRuntimeDriver()
}

@MainActor
private final class CGVirtualDisplayRuntimeHandle: VirtualDisplayRuntimeHandling {
    private let display: CGVirtualDisplay

    init(display: CGVirtualDisplay) {
        self.display = display
    }

    var serialNum: UInt32 {
        display.serialNum
    }

    var displayID: CGDirectDisplayID {
        display.displayID
    }

    func applyModes(_ modes: [ResolutionSelection]) -> Bool {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = modes.contains(where: { $0.enableHiDPI }) ? 1 : 0
        settings.modes = buildDisplayModes(from: modes)
        return display.apply(settings)
    }

    private func buildDisplayModes(from modes: [ResolutionSelection]) -> [CGVirtualDisplayMode] {
        var displayModes: [CGVirtualDisplayMode] = []
        for mode in modes {
            if mode.enableHiDPI {
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
