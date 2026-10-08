import CoreGraphics
import Foundation

package typealias PreservedVirtualDisplayMode = VirtualDisplayHostRequest.PreservedMode

@MainActor
package protocol VirtualDisplayModePreserving {
    func capture(_ displays: [PreservedVirtualDisplayMode]) throws -> [PreservedVirtualDisplayMode]
    func waitForDisconnection(serialNumber: UInt32) async throws
    func restore(_ displays: [PreservedVirtualDisplayMode]) throws
}

/// Mode commits belong to the login session, not the lifetime of one display host.
@MainActor
package struct SystemVirtualDisplayModePreserver: VirtualDisplayModePreserving {
    package init() {}

    package func capture(_ displays: [PreservedVirtualDisplayMode]) throws -> [PreservedVirtualDisplayMode] {
        try displays.map { display in
            guard CGDisplaySerialNumber(display.displayID) == display.serialNumber,
                  let mode = CGDisplayCopyDisplayMode(display.displayID) else {
                throw VirtualDisplayOperationError.creationFailed
            }
            return .init(displayID: display.displayID, serialNumber: display.serialNumber, mode: Self.snapshot(mode))
        }
    }

    package func waitForDisconnection(serialNumber: UInt32) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        let inspector = SystemDisplayTopologyInspector()
        while true {
            guard let topology = inspector.snapshot(
                trackedManagedSerials: [serialNumber],
                managedVendorID: ManagedVirtualDisplayIdentity.vendorID,
                managedProductID: ManagedVirtualDisplayIdentity.productID
            ) else {
                throw VirtualDisplayOperationError.teardownTimedOut
            }
            if !topology.displays.contains(where: \.isManagedVirtualDisplay) { return }
            guard ContinuousClock.now < deadline else {
                throw VirtualDisplayOperationError.teardownTimedOut
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    package func restore(_ displays: [PreservedVirtualDisplayMode]) throws {
        var assignments: [(CGDirectDisplayID, CGDisplayMode)] = []
        for display in displays {
            guard CGDisplayIsOnline(display.displayID) != 0 else { continue }
            guard CGDisplaySerialNumber(display.displayID) == display.serialNumber,
                  let current = CGDisplayCopyDisplayMode(display.displayID) else {
                throw VirtualDisplayOperationError.creationFailed
            }
            let available = CGDisplayCopyAllDisplayModes(
                display.displayID, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            ) as? [CGDisplayMode] ?? []
            guard let selected = ([current] + available).first(where: { Self.snapshot($0) == display.mode }) else {
                throw VirtualDisplayOperationError.creationFailed
            }
            assignments.append((display.displayID, selected))
        }
        guard !assignments.isEmpty else { return }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw VirtualDisplayOperationError.creationFailed
        }
        for (displayID, mode) in assignments {
            guard CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil) == .success else {
                CGCancelDisplayConfiguration(configuration)
                throw VirtualDisplayOperationError.creationFailed
            }
        }
        guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else {
            throw VirtualDisplayOperationError.creationFailed
        }
        for (displayID, mode) in assignments {
            guard let actual = CGDisplayCopyDisplayMode(displayID), Self.snapshot(actual) == Self.snapshot(mode) else {
                throw VirtualDisplayOperationError.creationFailed
            }
        }
    }

    package static func snapshot(_ mode: CGDisplayMode) -> VirtualDisplayRuntimeDisplayMode {
        .init(id: mode.ioDisplayModeID, width: mode.width, height: mode.height,
              pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
    }
}
