import VoidDisplayFoundation

/// Physical pixel envelope shared by creation, persistence and runtime descriptors.
enum VirtualDisplayModeBounds {
    static let maxPixelWidth = 8_192
    static let maxPixelHeight = 8_192
    static let maxPixelCount: UInt64 = 67_108_864

    enum ValidationError: String, Error {
        case noModes = "at least one resolution mode is required"
        case invalidDimensions = "resolution dimensions must be greater than 0"
        case invalidRefreshRate = "refresh rate must be finite and greater than 0"
        case dimensionsExceeded = "maximum pixel dimensions exceed the supported limit"
        case pixelCountExceeded = "maximum pixel count exceeds the supported limit"
    }

    static func resolve(_ modes: [ResolutionSelection]) throws(ValidationError) -> (width: UInt32, height: UInt32) {
        guard !modes.isEmpty else { throw .noModes }
        var width = 0
        var height = 0
        for mode in modes {
            guard mode.width > 0, mode.height > 0 else { throw .invalidDimensions }
            guard mode.refreshRate.isFinite, mode.refreshRate > 0 else { throw .invalidRefreshRate }
            let scale = mode.enableHiDPI ? 2 : 1
            guard mode.width <= maxPixelWidth / scale,
                  mode.height <= maxPixelHeight / scale else { throw .dimensionsExceeded }
            width = max(width, mode.width * scale)
            height = max(height, mode.height * scale)
        }
        guard UInt64(width) * UInt64(height) <= maxPixelCount else { throw .pixelCountExceeded }
        return (UInt32(width), UInt32(height))
    }
}
