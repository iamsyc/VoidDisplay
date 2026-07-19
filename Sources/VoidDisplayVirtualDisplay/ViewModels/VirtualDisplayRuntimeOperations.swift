import Foundation
import VoidDisplayFoundation

package struct VirtualDisplayCreateRequest: Equatable, Sendable {
    package let displayName: String
    package let serialNumber: UInt32
    package let physicalWidthMillimeters: UInt32
    package let physicalHeightMillimeters: UInt32
    package let maximumPixelWidth: UInt32
    package let maximumPixelHeight: UInt32
    package let modes: [ResolutionSelection]

    package init(
        displayName: String,
        serialNumber: UInt32,
        physicalWidthMillimeters: UInt32,
        physicalHeightMillimeters: UInt32,
        maximumPixelWidth: UInt32,
        maximumPixelHeight: UInt32,
        modes: [ResolutionSelection]
    ) {
        self.displayName = displayName
        self.serialNumber = serialNumber
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
        self.modes = modes
    }
}

package struct VirtualDisplayEditRebuildOperation: Sendable {
    private let saveTask: Task<Void, any Error>
    private let completionTask: Task<Void, any Error>

    package init(
        saveTask: Task<Void, any Error>,
        completionTask: Task<Void, any Error>
    ) {
        self.saveTask = saveTask
        self.completionTask = completionTask
    }

    package func waitForSave() async throws {
        try await saveTask.value
    }

    package func waitForCompletion() async throws {
        try await completionTask.value
    }
}
