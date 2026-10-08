import CGVirtualDisplayPrivate
import CoreGraphics
import Darwin
import Foundation
import VoidDisplayVirtualDisplay

/// One process owns one display. CoreGraphics mode queries must follow creation in this process;
/// after a mode switch, process exit is also required to reliably reclaim the native display.
@MainActor
public enum VirtualDisplayHost {
    public static func run() async {
        do {
            var input = FileHandle.standardInput.bytes.lines.makeAsyncIterator()
            guard let line = try await input.next() else { return }
            let request = try JSONDecoder().decode(VirtualDisplayHostRequest.self, from: Data(line.utf8))
            let display = try createDisplay(request.descriptor)
            let mode = try selectMode(displayID: display.displayID, requested: request.descriptor.modes,
                                      preserving: request.preservedModes)
            try respond(.ready(displayID: display.displayID, mode: mode))
            // EOF also covers an unexpected parent exit. Keep the native object alive until then.
            while try await input.next() != nil {}
            withExtendedLifetime(display) {}
        } catch {
            try? respond(.failed(String(describing: error)))
            exit(EXIT_FAILURE)
        }
    }

    private static func respond(_ response: VirtualDisplayHostResponse) throws {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func createDisplay(_ request: VirtualDisplayRuntimeDescriptor) throws -> CGVirtualDisplay {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.terminationHandler = { _, _ in exit(EXIT_FAILURE) }
        descriptor.name = request.name
        descriptor.maxPixelsWide = request.maximumPixelDimensions.width
        descriptor.maxPixelsHigh = request.maximumPixelDimensions.height
        descriptor.sizeInMillimeters = request.physicalSize
        descriptor.productID = ManagedVirtualDisplayIdentity.productID
        descriptor.vendorID = ManagedVirtualDisplayIdentity.vendorID
        descriptor.serialNum = request.serialNumber
        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = request.modes.contains(where: \.isHiDPI) ? 1 : 0
        settings.modes = request.modes.flatMap { mode in
            let standard = CGVirtualDisplayMode(width: UInt(mode.width), height: UInt(mode.height), refreshRate: mode.refreshRate)
            guard mode.isHiDPI else { return [standard] }
            return [CGVirtualDisplayMode(width: UInt(mode.width * 2), height: UInt(mode.height * 2), refreshRate: mode.refreshRate), standard]
        }
        guard display.displayID != 0, display.apply(settings) else {
            throw VirtualDisplayOperationError.creationFailed
        }
        return display
    }

    private static func selectMode(
        displayID: CGDirectDisplayID,
        requested: [VirtualDisplayRuntimeMode],
        preserving: [VirtualDisplayHostRequest.PreservedMode]
    ) throws -> VirtualDisplayRuntimeDisplayMode {
        let current = CGDisplayCopyDisplayMode(displayID).map(snapshot)
        let available = CGDisplayCopyAllDisplayModes(
            displayID, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        ) as? [CGDisplayMode] ?? []
        guard let selected = VirtualDisplayModeSelection.select(current: current, available: available.map(snapshot), requested: requested) else {
            throw VirtualDisplayOperationError.creationFailed
        }
        // Native creation can change another virtual display's logical size or HiDPI scale.
        let selectedMode = PreservedVirtualDisplayMode(
            displayID: displayID, serialNumber: CGDisplaySerialNumber(displayID), mode: selected
        )
        try SystemVirtualDisplayModePreserver().restore([selectedMode] + preserving)
        return selectedMode.mode
    }

    private static func snapshot(_ mode: CGDisplayMode) -> VirtualDisplayRuntimeDisplayMode {
        SystemVirtualDisplayModePreserver.snapshot(mode)
    }
}
