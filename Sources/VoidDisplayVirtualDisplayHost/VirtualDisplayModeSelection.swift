import VoidDisplayVirtualDisplay

package enum VirtualDisplayModeSelection {
    package typealias Mode = VirtualDisplayRuntimeDisplayMode

    package static func select(
        current: Mode?,
        available: [Mode],
        requested: [VirtualDisplayRuntimeMode]
    ) -> Mode? {
        if let current, requested.contains(where: { matches(current, requested: $0) }) {
            return current
        }
        for request in requested {
            if let mode = available.first(where: { matches($0, requested: request) }) {
                return mode
            }
        }
        return nil
    }

    private static func matches(_ mode: Mode, requested: VirtualDisplayRuntimeMode) -> Bool {
        let scale = requested.isHiDPI ? 2 : 1
        return mode.width == requested.width &&
            mode.height == requested.height &&
            mode.pixelWidth == requested.width * scale &&
            mode.pixelHeight == requested.height * scale &&
            // CoreGraphics reports virtual display refresh rates as whole Hertz.
            mode.refreshRate.rounded() == requested.refreshRate.rounded()
    }
}
