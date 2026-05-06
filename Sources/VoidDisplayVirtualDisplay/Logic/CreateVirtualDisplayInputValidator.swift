import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package struct CreateVirtualDisplayInputValidator {
    package static let maxPixelWidthLimit: UInt32 = 8_192
    package static let maxPixelHeightLimit: UInt32 = 8_192
    package static let maxPixelCountLimit: UInt64 = 67_108_864

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
        guard width > 0, height > 0, refreshRate.isFinite, refreshRate > 0 else {
            return .invalidValues
        }
        let logicalWidth = UInt64(width)
        let logicalHeight = UInt64(height)
        guard isWithinMaxPixelLimits(width: logicalWidth, height: logicalHeight) else {
            return .invalidValues
        }

        let newMode = ResolutionSelection(width: width, height: height, refreshRate: refreshRate)
        return appendIfUnique(mode: newMode, to: modes)
    }

    package static func maxPixelDimensions(for modes: [ResolutionSelection]) -> MaxPixelDimensionsResult {
        let validModes = modes.filter { $0.width > 0 && $0.height > 0 }
        guard let maxMode = validModes.max(by: { pixelArea(of: $0) < pixelArea(of: $1) }) else {
            return .invalidValues
        }

        let scale: UInt64 = validModes.contains { $0.enableHiDPI } ? 2 : 1
        let baseWidth = UInt64(maxMode.width)
        let baseHeight = UInt64(maxMode.height)
        let (scaledWidth, widthOverflow) = baseWidth.multipliedReportingOverflow(by: scale)
        let (scaledHeight, heightOverflow) = baseHeight.multipliedReportingOverflow(by: scale)
        guard !widthOverflow, !heightOverflow else {
            return .invalidValues
        }
        guard isWithinMaxPixelLimits(width: scaledWidth, height: scaledHeight) else {
            return .invalidValues
        }

        return .resolved(width: UInt32(scaledWidth), height: UInt32(scaledHeight))
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

    private static func pixelArea(of mode: ResolutionSelection) -> UInt64 {
        guard mode.width > 0, mode.height > 0 else { return 0 }
        let width = UInt64(mode.width)
        let height = UInt64(mode.height)
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? UInt64.max : area
    }

    private static func isWithinMaxPixelLimits(width: UInt64, height: UInt64) -> Bool {
        guard width <= UInt64(maxPixelWidthLimit),
              height <= UInt64(maxPixelHeightLimit) else {
            return false
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && count <= maxPixelCountLimit
    }
}
