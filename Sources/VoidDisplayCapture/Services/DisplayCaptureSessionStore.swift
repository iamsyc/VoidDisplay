import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
import CoreVideo
import Synchronization
package struct DisplayCaptureSessionStore {
    package struct Record: Sendable {
        let session: any DisplayCaptureSessioning
        let resolutionText: String
        var state: DisplayCaptureRegistry.SessionResourceState
    }

    private var recordsByDisplayID: [CGDirectDisplayID: Record] = [:]
    private var sessionDrainTasksByDisplayID: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var initializingDisplayIDs: Set<CGDirectDisplayID> = []

    package var activeDisplayIDs: [CGDirectDisplayID] {
        recordsByDisplayID.compactMap { displayID, record in
            record.state == .draining ? nil : displayID
        }
    }

    package func record(for displayID: CGDirectDisplayID) -> Record? {
        recordsByDisplayID[displayID]
    }

    package func sessionState(
        for displayID: CGDirectDisplayID
    ) -> DisplayCaptureRegistry.SessionResourceState {
        if initializingDisplayIDs.contains(displayID) {
            return .initializing
        }
        return recordsByDisplayID[displayID]?.state ?? .stopped
    }

    package mutating func installSessionForTesting(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning
    ) {
        sessionDrainTasksByDisplayID[displayID]?.cancel()
        sessionDrainTasksByDisplayID[displayID] = nil
        initializingDisplayIDs.remove(displayID)
        recordsByDisplayID[displayID] = Record(
            session: session,
            resolutionText: resolutionText,
            state: .active
        )
    }

    package mutating func markActive(displayID: CGDirectDisplayID) {
        guard var record = recordsByDisplayID[displayID] else { return }
        record.state = .active
        recordsByDisplayID[displayID] = record
    }

    package mutating func markInitializing(displayID: CGDirectDisplayID) {
        initializingDisplayIDs.insert(displayID)
    }

    package mutating func cancelInitializing(displayID: CGDirectDisplayID) {
        initializingDisplayIDs.remove(displayID)
    }

    package mutating func storeInitializedSessionIfAbsent(
        _ record: Record,
        for displayID: CGDirectDisplayID
    ) {
        initializingDisplayIDs.remove(displayID)
        guard recordsByDisplayID[displayID] == nil else { return }
        recordsByDisplayID[displayID] = record
    }

    package func drainTask(for displayID: CGDirectDisplayID) -> Task<Void, Never>? {
        sessionDrainTasksByDisplayID[displayID]
    }

    package mutating func beginDraining(
        displayID: CGDirectDisplayID,
        onStopCompleted: @escaping @Sendable (CGDirectDisplayID) async -> Void
    ) {
        guard var record = recordsByDisplayID[displayID] else { return }
        record.state = .draining
        recordsByDisplayID[displayID] = record

        let session = record.session
        sessionDrainTasksByDisplayID[displayID]?.cancel()
        sessionDrainTasksByDisplayID[displayID] = Task { [displayID] in
            await session.stop()
            await onStopCompleted(displayID)
        }
    }

    package mutating func finishDraining(displayID: CGDirectDisplayID, hasActiveTokens: Bool) {
        sessionDrainTasksByDisplayID[displayID] = nil
        guard let record = recordsByDisplayID[displayID] else { return }
        guard record.state == .draining else { return }

        if hasActiveTokens {
            var resumedRecord = record
            resumedRecord.state = .active
            recordsByDisplayID[displayID] = resumedRecord
            return
        }

        recordsByDisplayID.removeValue(forKey: displayID)
    }
}
