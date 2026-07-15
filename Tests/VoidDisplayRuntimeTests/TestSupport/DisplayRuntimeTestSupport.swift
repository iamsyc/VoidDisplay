@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation

func visibleDisplays(from catalog: DisplayRuntimeCatalogSnapshot) -> [DisplayRuntimeVisibleDisplay] {
    catalog.loadedDisplays.map {
        DisplayRuntimeVisibleDisplay(
            displayID: $0.displayID,
            pixelWidth: $0.pixelWidth,
            pixelHeight: $0.pixelHeight
        )
    }
}

func fastTopologyWaitPolicy(maximumSampleCount: Int = 3) -> DisplayRuntimeTopologyWaitPolicy {
    .init(
        requiredStableSampleCount: 2,
        maximumSampleCount: maximumSampleCount,
        sampleIntervalNanoseconds: 0
    )
}

func editConfigDTO(
    id: UUID,
    displayName: String,
    serial: UInt32,
    desiredEnabled: Bool = true,
    physicalWidthMillimeters: UInt32 = 600,
    physicalHeightMillimeters: UInt32 = 340,
    modes: [DisplayRuntimeVirtualDisplayModeDTO] = [
        .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
    ]
) -> DisplayRuntimeVirtualDisplayConfigEditDTO {
    let maximumPixelDimensions = maximumPixelDimensions(for: modes)
    return DisplayRuntimeVirtualDisplayConfigEditDTO(
        id: id,
        displayName: displayName,
        serialNumber: serial,
        desiredEnabled: desiredEnabled,
        physicalWidthMillimeters: physicalWidthMillimeters,
        physicalHeightMillimeters: physicalHeightMillimeters,
        modes: modes,
        maximumPixelWidth: maximumPixelDimensions.width,
        maximumPixelHeight: maximumPixelDimensions.height
    )
}

func maximumPixelDimensions(
    for modes: [DisplayRuntimeVirtualDisplayModeDTO]
) -> (width: UInt32, height: UInt32) {
    guard let maxMode = modes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
        return (0, 0)
    }
    let scale = modes.contains(where: \.enableHiDPI) ? 2 : 1
    return (
        UInt32(clamping: maxMode.width * scale),
        UInt32(clamping: maxMode.height * scale)
    )
}

@MainActor
final class RuntimeOperationRecorder {
    var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}
