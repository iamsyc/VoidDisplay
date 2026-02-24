import Foundation
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class DisplaySharingCoordinator {
    struct ShareableDisplayRegistrationInput {
        let displayID: CGDirectDisplayID
        let isMain: Bool
        let virtualSerial: UInt32?
    }

    private struct DisplayRegistration {
        let displayID: CGDirectDisplayID
        let shareID: UInt32
        let isMain: Bool
    }

    private struct SharingSession {
        let stream: SCStream
        let capture: Capture
        let delegate: StreamDelegate
    }

    private var registrationsByDisplayID: [CGDirectDisplayID: DisplayRegistration] = [:]
    private var displayIDsByShareID: [UInt32: CGDirectDisplayID] = [:]
    private var sessionsByDisplayID: [CGDirectDisplayID: SharingSession] = [:]
    private var mainDisplayID: CGDirectDisplayID?
    private let idStore: DisplayShareIDStore

    init(idStore: DisplayShareIDStore? = nil) {
        self.idStore = idStore ?? DisplayShareIDStore()
    }

    var hasAnyActiveSharing: Bool {
        !sessionsByDisplayID.isEmpty
    }

    var activeSharingDisplayIDs: Set<CGDirectDisplayID> {
        Set(sessionsByDisplayID.keys)
    }

    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    ) {
        let inputs = displays.map { display in
            let displayID = display.displayID
            return ShareableDisplayRegistrationInput(
                displayID: displayID,
                isMain: CGDisplayIsMain(displayID) != 0,
                virtualSerial: virtualSerialResolver(displayID)
            )
        }
        registerShareableDisplays(inputs)
    }

    func registerShareableDisplays(_ inputs: [ShareableDisplayRegistrationInput]) {
        var nextRegistrationsByDisplayID: [CGDirectDisplayID: DisplayRegistration] = [:]
        var nextDisplayIDsByShareID: [UInt32: CGDirectDisplayID] = [:]
        var resolvedMainDisplayID: CGDirectDisplayID?
        var reservedShareIDs = Set<UInt32>()

        let virtualInputs = inputs
            .filter { $0.virtualSerial != nil }
            .sorted {
                let lhsSerial = $0.virtualSerial ?? 0
                let rhsSerial = $1.virtualSerial ?? 0
                if lhsSerial != rhsSerial { return lhsSerial < rhsSerial }
                return $0.displayID < $1.displayID
            }
        for (index, input) in virtualInputs.enumerated() {
            let shareID = input.virtualSerial ?? UInt32(index + 1)
            reservedShareIDs.insert(shareID)
            if input.isMain {
                resolvedMainDisplayID = input.displayID
            }
            let registration = DisplayRegistration(
                displayID: input.displayID,
                shareID: shareID,
                isMain: input.isMain
            )
            nextRegistrationsByDisplayID[input.displayID] = registration
            nextDisplayIDsByShareID[shareID] = input.displayID
        }

        let physicalInputs = inputs
            .filter { $0.virtualSerial == nil }
            .sorted { $0.displayID < $1.displayID }
        for input in physicalInputs {
            if input.isMain, resolvedMainDisplayID == nil {
                resolvedMainDisplayID = input.displayID
            }
            let identityKey = makeIdentityKey(for: input.displayID)
            let shareID = idStore.assignID(for: identityKey, excluding: reservedShareIDs)
            reservedShareIDs.insert(shareID)
            let registration = DisplayRegistration(
                displayID: input.displayID,
                shareID: shareID,
                isMain: input.isMain
            )
            nextRegistrationsByDisplayID[input.displayID] = registration
            nextDisplayIDsByShareID[shareID] = input.displayID
        }

        registrationsByDisplayID = nextRegistrationsByDisplayID
        displayIDsByShareID = nextDisplayIDsByShareID
        mainDisplayID = resolvedMainDisplayID ?? mainDisplayID

        let registeredDisplayIDs = Set(nextRegistrationsByDisplayID.keys)
        for displayID in Array(sessionsByDisplayID.keys) where !registeredDisplayIDs.contains(displayID) {
            stopSharing(displayID: displayID)
        }
    }

    func shareID(for displayID: CGDirectDisplayID) -> UInt32? {
        registrationsByDisplayID[displayID]?.shareID
    }

    func displayID(for shareID: UInt32) -> CGDirectDisplayID? {
        displayIDsByShareID[shareID]
    }

    func isSharing(displayID: CGDirectDisplayID) -> Bool {
        sessionsByDisplayID[displayID] != nil
    }

    func startSharing(
        displayID: CGDirectDisplayID,
        stream: SCStream,
        capture: Capture,
        delegate: StreamDelegate
    ) {
        stopSharing(displayID: displayID)
        sessionsByDisplayID[displayID] = SharingSession(
            stream: stream,
            capture: capture,
            delegate: delegate
        )
        if CGDisplayIsMain(displayID) != 0 {
            mainDisplayID = displayID
        }
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        guard let session = sessionsByDisplayID.removeValue(forKey: displayID) else { return }
        session.stream.stopCapture()
        session.capture.resetFrameState()
        _ = session.delegate
    }

    func stopAllSharing() {
        for displayID in Array(sessionsByDisplayID.keys) {
            stopSharing(displayID: displayID)
        }
    }

    func state(for target: ShareTarget) -> ShareTargetState {
        switch target {
        case .main:
            if let resolvedMainID = resolvedMainDisplayID(),
               sessionsByDisplayID[resolvedMainID] != nil {
                return .active
            }
            return .knownInactive
        case .id(let id):
            guard let displayID = displayIDsByShareID[id] else {
                return .unknown
            }
            return sessionsByDisplayID[displayID] != nil ? .active : .knownInactive
        }
    }

    func frame(for target: ShareTarget) -> Data? {
        switch target {
        case .main:
            if let resolvedMainID = resolvedMainDisplayID() {
                return sessionsByDisplayID[resolvedMainID]?.capture.jpgData
            }
            return nil
        case .id(let id):
            guard let displayID = displayIDsByShareID[id] else { return nil }
            return sessionsByDisplayID[displayID]?.capture.jpgData
        }
    }

    func target(for displayID: CGDirectDisplayID) -> ShareTarget? {
        guard let id = registrationsByDisplayID[displayID]?.shareID else { return nil }
        return .id(id)
    }

    private func resolvedMainDisplayID() -> CGDirectDisplayID? {
        if let mainDisplayID,
           registrationsByDisplayID[mainDisplayID] != nil || sessionsByDisplayID[mainDisplayID] != nil {
            return mainDisplayID
        }

        if let registeredMain = registrationsByDisplayID.values.first(where: { $0.isMain })?.displayID {
            mainDisplayID = registeredMain
            return registeredMain
        }

        let systemMain = CGMainDisplayID()
        if registrationsByDisplayID[systemMain] != nil || sessionsByDisplayID[systemMain] != nil {
            mainDisplayID = systemMain
            return systemMain
        }
        return nil
    }

    private func makeIdentityKey(for displayID: CGDirectDisplayID) -> String {
        if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let cfUUID = unmanagedUUID.takeRetainedValue()
            let uuidString = CFUUIDCreateString(nil, cfUUID) as String
            return "physical:\(uuidString.lowercased())"
        }
        return "physical-display-id:\(displayID)"
    }
}
