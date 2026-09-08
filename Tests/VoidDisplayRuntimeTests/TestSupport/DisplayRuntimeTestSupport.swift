@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation

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
    physicalHeightMillimeters: UInt32 = 340
) -> DisplayRuntimeVirtualDisplayConfigEditDTO {
    DisplayRuntimeVirtualDisplayConfigEditDTO(
        id: id,
        displayName: displayName,
        serialNumber: serial,
        desiredEnabled: desiredEnabled,
        physicalWidthMillimeters: physicalWidthMillimeters,
        physicalHeightMillimeters: physicalHeightMillimeters,
        modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
        maximumPixelWidth: 1920,
        maximumPixelHeight: 1080
    )
}

@MainActor
final class RuntimeOperationRecorder {
    var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}
