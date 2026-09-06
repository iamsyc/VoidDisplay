import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package struct CreateVirtualDisplayInputValidator {
    package enum MaxPixelDimensionsResult: Equatable {
        case resolved(width: UInt32, height: UInt32)
        case invalidValues
    }

    package enum AddModeResult: Equatable {
        case appended([ResolutionSelection])
        case duplicate
        case invalidValues
    }

    package static func addPresetMode(
        preset: DisplayResolutionPreset,
        to modes: [ResolutionSelection]
    ) -> AddModeResult {
        let newMode = ResolutionSelection(preset: preset)
        return appendIfUnique(mode: newMode, to: modes)
    }

    package static func addCustomMode(
        width: Int,
        height: Int,
        refreshRate: Double,
        to modes: [ResolutionSelection]
    ) -> AddModeResult {
        // Validate the logical size here so HiDPI can still be changed in the form.
        guard (try? VirtualDisplayModeBounds.resolve([
            .init(width: width, height: height, refreshRate: refreshRate, enableHiDPI: false)
        ])) != nil else {
            return .invalidValues
        }

        let newMode = ResolutionSelection(width: width, height: height, refreshRate: refreshRate)
        return appendIfUnique(mode: newMode, to: modes)
    }

    package static func maxPixelDimensions(for modes: [ResolutionSelection]) -> MaxPixelDimensionsResult {
        guard let dimensions = try? VirtualDisplayModeBounds.resolve(modes) else {
            return .invalidValues
        }
        return .resolved(width: dimensions.width, height: dimensions.height)
    }

    package static func defaultName(baseName: String, serialNum: UInt32) -> String {
        "\(baseName) \(serialNum)"
    }

    package static func initializeNameAndSerial(
        currentName: String,
        baseName: String,
        nextSerial: UInt32
    ) -> (name: String, serialNum: UInt32) {
        let name = currentName == baseName
            ? defaultName(baseName: baseName, serialNum: nextSerial)
            : currentName
        return (name, nextSerial)
    }

    private static func appendIfUnique(
        mode: ResolutionSelection,
        to modes: [ResolutionSelection]
    ) -> AddModeResult {
        if modes.contains(where: { $0.matchesResolution(of: mode) }) {
            return .duplicate
        }

        var updated = modes
        updated.append(mode)
        return .appended(updated)
    }
}
