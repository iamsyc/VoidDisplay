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
            let request = try JSONDecoder().decode(VirtualDisplayRuntimeDescriptor.self, from: Data(line.utf8))
            let display = try createDisplay(request)
            let mode = try selectMode(displayID: display.displayID, requested: request.modes)
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

    private static func selectMode(displayID: CGDirectDisplayID, requested: [VirtualDisplayRuntimeMode]) throws -> VirtualDisplayRuntimeDisplayMode {
        let current = CGDisplayCopyDisplayMode(displayID).map(snapshot)
        let available = CGDisplayCopyAllDisplayModes(
            displayID, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        ) as? [CGDisplayMode] ?? []
        guard let selected = VirtualDisplayModeSelection.select(current: current, available: available.map(snapshot), requested: requested) else {
            throw VirtualDisplayOperationError.creationFailed
        }
        if current?.id != selected.id {
            guard let mode = available.first(where: { $0.ioDisplayModeID == selected.id }),
                  CGDisplaySetDisplayMode(displayID, mode, nil) == .success else {
                throw VirtualDisplayOperationError.creationFailed
            }
        }
        guard let actual = CGDisplayCopyDisplayMode(displayID).map(snapshot),
              VirtualDisplayModeSelection.select(current: actual, available: [], requested: requested) != nil else {
            throw VirtualDisplayOperationError.creationFailed
        }
        return actual
    }

    private static func snapshot(_ mode: CGDisplayMode) -> VirtualDisplayRuntimeDisplayMode {
        .init(id: mode.ioDisplayModeID, width: mode.width, height: mode.height,
              pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
    }
}
